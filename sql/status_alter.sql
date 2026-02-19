USE [peerVue]
GO
/****** Object:  StoredProcedure [dbo].[pri_site_status]    Script Date: 1/12/2026 3:18:36 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
ALTER procedure [dbo].[pri_site_status]
as
begin
	set nocount on
	select siteName, Count(Distinct(AssignedCaseID)) workloadCount, GETDATE() fetchDate,
		Assigned_Under_24  = count (Distinct case when AssignedAgeHours < 24  then AssignedCaseId end),
		Assigned_Under_48  = count (Distinct case when AssignedAgeHours between 24 and  47 then AssignedCaseId end),
		Assigned_Under_72 =  count (Distinct case when AssignedAgeHours between 48 and  72 then AssignedCaseId end),
		Assigned_Over_72 = count (Distinct case when AssignedAgeHours > 72 then AssignedCaseId end)

	--Created0to24   = count (Distinct case when CreatedAgeHours < 24   then AssignedCaseId end),
	--Created24to48  = count (Distinct case when CreatedAgeHours between 24 and  47 then AssignedCaseId end),
	--Created48to72 = count (Distinct case when CreatedAgeHours between 48 and  72 then AssignedCaseId end),
	--Created72Plus = count (Distinct case when CreatedAgeHours >  72 then AssignedCaseId end)
	from (
			Select 'Mercy' siteName,
				AssignedCaseID, CreatedAgeHours = DATEDIFF(hour, CreatedDate, getdate()) 
	, AssignedAgeHours = DATEDIFF(hour, CreatedDate, getdate())
			from Qi_AssignedCases A
				Left Join T_CASES_ROLES AR on AR.case_id=A.AssignedCaseId
				Left Join Roles R on R.RoleID=AR.role_id
				Left Join Hl7StudyOld H on H.HL7Study_PK=A.Qi_HL7StudyID
			Where CaseStatus=1
				and A.PacsID=4 -- [peerVue].[dbo].[VW_PACSInfo]
				and ToQiSpaceId=15 --- mean it needs to be interpretation // [peerVue].[dbo].[Qi_QiSpaces]
				and examstatus = 'REVIEWED'
				and rolename not in ('Division - Diagnostic Mammo','Division - Interventional', 'Division - Screening Mammo','Division - Cardiac MRI','Division - General')

		union all
			Select 'TCH' siteName,
				AssignedCaseID, CreatedAgeHours = DATEDIFF(hour, CreatedDate, getdate()) 
	, AssignedAgeHours = DATEDIFF(hour, CreatedDate, getdate())
			from Qi_AssignedCases A
				Left Join T_CASES_ROLES AR on AR.case_id=A.AssignedCaseId
				Left Join Roles R on R.RoleID=AR.role_id
				Left Join Hl7StudyOld H on H.HL7Study_PK=A.Qi_HL7StudyID
			Where CaseStatus=1 and A.PacsID=1 and ToQiSpaceId=15
				AND Modality in ('CR' , 'CT' , 'DS' , 'DX' , 'MR' , 'NM' , 'PT' , 'RF' , 'RG' , 'US')
				AND ExamStatus in ('Reviewed')
				AND (RoleName in ('Administrators' , 'Division - Body' , 'Division - Cardiac MRI' , 'Division - General' , 'Division - MSK' , 'Division - Neuro' , 'Division - Nuclear Medicine' , 'Division - Uncategorized' , 'Division - Vascular US' , 'Domain Users' , 'Emergency Department' , 'Lead Tech' , 'ordering Physician' , 'QI Committee' , 'Radiologist' , 'Radiologist Resident' , 'Referring Physician' , 'Server Operators' , 'Site Administrator' , 'Technologist')
				OR RoleName IS NULL)
) as k
	group by siteName

end
 go

exec  [dbo].[pri_site_status]