/*>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
CQUIN REPORTING

ASSET: PRE-PROCESSED TABLES

CREATED BY CARL MONEY 20/05/2020

>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>*/

--SET VARIABLES

DECLARE @StartRP INT

SET @StartRP = 1429 --April 2019

DECLARE @EndRP INT

SET @EndRP	= (SELECT UniqMonthID
FROM NHSE_Sandbox_MentalHealth.dbo.PreProc_Header
WHERE Der_MostRecentFlag = 'P')

DECLARE @ReportingPeriodEnd DATE

SET @ReportingPeriodEnd = (SELECT ReportingPeriodEndDate
FROM NHSE_Sandbox_MentalHealth.dbo.PreProc_Header
WHERE Der_MostRecentFlag = 'P')

/*>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
PAIRED OUTCOME CQUIN
>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>*/

/*>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
GET ALL CLOSED REFERRALS
>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>*/

IF OBJECT_ID ('tempdb..#Ref') IS NOT NULL
DROP TABLE #Ref

SELECT
	r.UniqMonthID,
	r.Person_ID,
	r.UniqServReqID,
	r.RecordNumber,
	r.OrgIDProv,
	r.AgeServReferRecDate,
	r.ReferralRequestReceivedDate,
	r.ServDischDate,
	r.ServTeamTypeRefToMH,
	r.ReferClosReason,
	r.DischPlanCreationDate,
	DATEDIFF(DD,r.ReferralRequestReceivedDate, r.ServDischDate) AS Der_ReferralLength,
	CASE 
		WHEN r.AgeServReferRecDate < 18 THEN 'CYP'
		WHEN r.ServTeamTypeRefToMH = 'C02' THEN 'Perinatal'
		ELSE 'Community'
	END AS Der_ServiceType

INTO #Ref

FROM NHSE_Sandbox_MentalHealth.dbo.PreProc_Referral r

LEFT JOIN 
	(SELECT i.Person_ID, i.UniqServReqID, COUNT(i.Der_HospSpellRecordOrder) AS Der_HospSpellCount
	FROM [NHSE_Sandbox_MentalHealth].[dbo].[PreProc_Inpatients] i
	GROUP BY i.Person_ID, i.UniqServReqID) i ON i.Person_ID = r.Person_ID AND i.UniqServReqID = r.UniqServReqID -- to indentify referrals to inpatient services

WHERE r.UniqMonthID BETWEEN @StartRP AND @EndRP

AND ((r.ServTeamTypeRefToMH IN ('A02','A03','A04','A05','A06','A07','A08','A09','A10','A12','A13','A16','C02','C03','C09','C10') 
	OR r.ServTeamTypeRefToMH IS NULL) OR r.AgeServReferRecDate <18) -- to include specific teams and everyone under 18 at the time of the referral

AND r.ServDischDate IS NOT NULL -- to include closed referrals only

AND i.Der_HospSpellCount IS NULL --to exclude referrals with an associated hospital spell

/*>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
GET ALL CONTACTS
>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>*/

IF OBJECT_ID ('tempdb..#Cont') IS NOT NULL
DROP TABLE #Cont

SELECT
	r.UniqMonthID,
	r.Person_ID,
	r.UniqServReqID,
	r.RecordNumber,
	r.OrgIDProv,
	MAX(a.Der_ContactOrder) - MIN(a.Der_ContactOrder) AS Der_ContInd, --counting indirect AND attended direct activity (excluding SMS or email) for the <18s
	MAX(a.Der_DirectContactOrder) - MIN(a.Der_DirectContactOrder) AS Der_ContDir, -- excluding indirect and direct SMS or email activity for >=18s
	MAX(a.Der_FacetoFaceContactOrder) - MIN(a.Der_FacetoFaceContactOrder) AS Der_ContF2F -- counting face to face contacts only for perinatal services

INTO #Cont

FROM #Ref r

INNER JOIN NHSE_Sandbox_MentalHealth.dbo.PreProc_Activity a ON a.Person_ID = r.Person_ID and a.UniqServReqID = r.UniqServReqID

WHERE a.UniqMonthID >= @StartRP -- to only count contacts in the financial year

GROUP BY r.UniqMonthID, r.Person_ID, r.UniqServReqID, r.RecordNumber, r.OrgIDProv

/*>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
GET ALL ASSESSMENTS
>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>*/

IF OBJECT_ID ('tempdb..#Ass') IS NOT NULL
DROP TABLE #Ass

SELECT
	r.UniqMonthID,
	r.Person_ID,
	r.UniqServReqID,
	r.RecordNumber,
	r.OrgIDProv,
	a.Der_AssToolCompDate, -- the completion date of the assessment
	a.CodedAssToolType,
	a.Der_AssessmentToolName, --the tool name from the MHSDS reference table in the TOS
	a.Der_PreferredTermSNOMED, --the preferred term for the assessment scale
	a.Der_AssOrderAsc, --First assessment
	a.Der_AssOrderDesc -- Last assessment

INTO #Ass

FROM #Ref r

INNER JOIN NHSE_Sandbox_MentalHealth.dbo.PreProc_Assessments a ON a.Person_ID = r.Person_ID AND a.UniqServReqID = r.UniqServReqID 

WHERE a.Der_ValidScore = 'Y' -- removes records with invalid scores

/*>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
CREATE MASTER TABLE THAT JOINS CONTACTS AND 
ASSESSMENTS TO REFERRALS
>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>*/

IF OBJECT_ID ('tempdb..#Master') IS NOT NULL
DROP TABLE #Master

SELECT
	r.UniqMonthID,
	r.Person_ID,
	r.UniqServReqID,
	r.RecordNumber,
	r.OrgIDProv,
	r.AgeServReferRecDate,
	r.ReferralRequestReceivedDate,
	r.ServDischDate,
	r.ServTeamTypeRefToMH,
	r.ReferClosReason,
	r.DischPlanCreationDate,
	r.Der_ReferralLength,
	r.Der_ServiceType,
	CASE
		WHEN r.AgeServReferRecDate <18 THEN c.Der_ContInd
		ELSE c.Der_ContDir
	END AS Der_InYearContacts,
	a1.Der_AssToolCompDate AS Der_FirstAssessmentDate,
	a1.Der_AssessmentToolName AS Der_FirstAssessmentToolName,
	a2.Der_AssToolCompDate AS Der_LastAssessmentDate,
	a2.Der_AssessmentToolName AS Der_LastAssessmentToolName,
	CASE 
		WHEN r.ReferralRequestReceivedDate >= '2016-01-01' 
		THEN DATEDIFF(DD, r.ReferralRequestReceivedDate, a1.Der_AssToolCompDate) 
	END AS Der_ReftoFirstAss, --limited to those referrals that were received after the MHSDS started
	DATEDIFF(DD,a2.Der_AssToolCompDate, r.ServDischDate) AS Der_LastAsstoDisch

INTO #Master

FROM #Ref r

LEFT JOIN #Cont c ON c.Person_ID = r.Person_ID AND c.UniqServReqID = r.UniqServReqID

LEFT JOIN #Ass a1 ON a1.Person_ID = r.Person_ID AND a1.UniqServReqID = r.UniqServReqID AND a1.Der_AssOrderAsc = 1

LEFT JOIN #Ass a2 ON a2.Person_ID = r.Person_ID AND a2.UniqServReqID = r.UniqServReqID AND a1.CodedAssToolType = a2.CodedAssToolType AND a2.Der_AssToolCompDate > a1.Der_AssToolCompDate AND a2.Der_AssOrderDesc = 1

/*>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
AGGREGATE AT REFERRAL LEVEL
>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>*/

IF OBJECT_ID ('tempdb..#RefAgg') IS NOT NULL
DROP TABLE #RefAgg

SELECT
	m.UniqMonthID,
	m.OrgIDProv AS [Organisation Code],
	m.Der_ServiceType AS [Service Type],
	'All' AS [Assessment Name],
	COUNT(DISTINCT m.UniqServReqID) AS [Closed Referrals],
	COUNT(DISTINCT CASE WHEN m.Der_ReferralLength >14 THEN UniqServReqID END) AS [Closed referrals open more than 14 days],
	COUNT(DISTINCT CASE WHEN m.Der_ReferralLength >14 AND m.Der_InYearContacts = 1 THEN m.UniqServReqID END) AS [Closed referrals open more than 14 days with one contact],
	COUNT(DISTINCT CASE WHEN m.Der_ReferralLength >14 AND m.Der_InYearContacts >1 THEN m.UniqServReqID END) AS [Closed referrals open more than 14 days with two or more contacts],
	COUNT(DISTINCT CASE WHEN m.Der_ReferralLength >14 AND m.Der_InYearContacts >1 AND m.Der_FirstAssessmentDate IS NOT NULL THEN m.UniqServReqID END) AS [Closed referrals open more than 14 days with two or more contacts and one assessment],
	COUNT(DISTINCT CASE WHEN m.Der_ReferralLength >14 AND m.Der_InYearContacts >1 AND m.Der_LastAssessmentDate IS NOT NULL THEN m.UniqServReqID END) AS [Closed referrals open more than 14 days with two or more contacts and a paired score]

INTO #RefAgg

FROM #Master m

GROUP BY m.UniqMonthID, m.OrgIDProv, m.Der_ServiceType

/*>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
AGGREGATE AT ASSESSMENT LEVEL
>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>*/

IF OBJECT_ID ('tempdb..#AssAgg') IS NOT NULL
DROP TABLE #AssAgg

SELECT
	m.UniqMonthID,
	m.OrgIDProv AS [Organisation Code],
	m.Der_ServiceType AS [Service Type],
	m.Der_LastAssessmentToolName AS [Assessment Name],
	COUNT(DISTINCT m.UniqServReqID) AS [Number of paired scores],
	AVG(Der_ReftoFirstAss) AS [Average days from referral received to first assessment],
	AVG(Der_LastAsstoDisch) AS [Average days from last assessment to referral closure]

INTO #AssAgg

FROM #Master m

WHERE m.Der_LastAssessmentDate IS NOT NULL

GROUP BY m.UniqMonthID, m.OrgIDProv, m.Der_ServiceType, m.Der_LastAssessmentToolName

/*>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
UNPIVOT
>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>*/

IF OBJECT_ID ('tempdb..#UnPiv') IS NOT NULL
DROP TABLE #UnPiv

SELECT 
	UniqMonthID,
	[Organisation Code],
	[Service Type],
	[Assessment Name],
	MeasureName,
	MeasureValue

INTO #Unpiv

FROM #RefAgg 

UNPIVOT 
(
 MeasureValue FOR MeasureName IN ([Closed Referrals], [Closed referrals open more than 14 days], [Closed referrals open more than 14 days with one contact], 
	[Closed referrals open more than 14 days with two or more contacts], [Closed referrals open more than 14 days with two or more contacts and one assessment], 
	[Closed referrals open more than 14 days with two or more contacts and a paired score])
 ) as RefAgg_U

UNION ALL	

SELECT 
	UniqMonthID,
	[Organisation Code],
	[Service Type],
	[Assessment Name],
	MeasureName,
	MeasureValue

FROM #AssAgg 

UNPIVOT 
(
 MeasureValue FOR MeasureName IN ([Number of paired scores], [Average days from referral received to first assessment], [Average days from last assessment to referral closure])
 ) as AssAgg_U

/*>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
LINK TO REFERENCE DATA AND CREATE EXTRACT
>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>*/

IF OBJECT_ID ('[NHSE_Sandbox_MentalHealth].[dbo].[Dashboard_CQUIN2021]') IS NOT NULL
DROP TABLE [NHSE_Sandbox_MentalHealth].[dbo].[Dashboard_CQUIN2021]

SELECT
	h.ReportingPeriodEndDate,
	CASE 
		WHEN YEAR(dateadd(month, 9, ReportingPeriodEndDate)) = '2020' THEN '19/20' 
		ELSE '20/21' 
	END AS FinancialYear,
	p.Region_Code,
	p.Region_Name,
	p.STP_Code,
	p.STP_Name,
	u.[Organisation Code],
	p.Organisation_Name,
	u.[Service Type],
	u.[Assessment Name],
	u.MeasureName,
	u.MeasureValue,
	u2.MeasureValue AS Denominator

INTO NHSE_Sandbox_MentalHealth.dbo.Dashboard_CQUIN2021

FROM #Unpiv u

LEFT JOIN NHSE_Sandbox_MentalHealth.dbo.PreProc_Header h ON u.UniqMonthID = h.UniqMonthID

LEFT JOIN NHSE_Reference.dbo.tbl_Ref_ODS_Provider_Hierarchies p ON u.[Organisation Code] = p.Organisation_Code

-- this join gets the denominator to calculate the percentage in Tableau

LEFT JOIN #Unpiv u2 ON u.UniqMonthID = u2.UniqMonthID AND u.[Organisation Code] = u2.[Organisation Code] AND u.[Service Type] = u2.[Service Type] AND
	u.[Assessment Name] = u2.[Assessment Name] AND u.MeasureName = 'Closed referrals open more than 14 days with two or more contacts and a paired score' 
	AND u2.MeasureName = 'Closed referrals open more than 14 days with two or more contacts'