@echo off
:: Creates the IAM role that Terraform will assume to deploy Langfuse.
:: Run this once with admin credentials BEFORE running terraform.
::
:: Usage:
::   iam-setup\create-role.cmd [role-name]
::
:: Default role name: langfuse-terraform-deployer

setlocal EnableDelayedExpansion

set "ROLE_NAME=%~1"
if "%ROLE_NAME%"=="" set "ROLE_NAME=langfuse-terraform-deployer"

set "POLICY_1_NAME=langfuse-terraform-networking-storage"
set "POLICY_2_NAME=langfuse-terraform-app-services"
set "POLICY_3_NAME=langfuse-terraform-app-services-2"
set "SCRIPT_DIR=%~dp0"

:: Remove trailing backslash from SCRIPT_DIR
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

:: -------------------------------------------------------
:: Get caller identity
:: -------------------------------------------------------
echo.
echo ==^> Getting current caller identity...
for /f "delims=" %%i in ('aws sts get-caller-identity --query Account --output text') do set "ACCOUNT_ID=%%i"
for /f "delims=" %%i in ('aws sts get-caller-identity --query Arn --output text') do set "CALLER_ARN=%%i"

if "%ACCOUNT_ID%"=="" (
    echo ERROR: Could not retrieve AWS account ID. Check your AWS credentials.
    exit /b 1
)

echo     Account : %ACCOUNT_ID%
echo     Caller  : %CALLER_ARN%

:: -------------------------------------------------------
:: Write trust policy to temp file
:: -------------------------------------------------------
set "TRUST_POLICY_FILE=%TEMP%\langfuse-trust-policy.json"
(
echo {
echo   "Version": "2012-10-17",
echo   "Statement": [
echo     {
echo       "Effect": "Allow",
echo       "Principal": {
echo         "AWS": "%CALLER_ARN%"
echo       },
echo       "Action": "sts:AssumeRole"
echo     }
echo   ]
echo }
) > "%TRUST_POLICY_FILE%"

:: -------------------------------------------------------
:: 1. Create the role (idempotent: skip if exists)
:: -------------------------------------------------------
echo.
echo ==^> Creating IAM role: %ROLE_NAME%...
aws iam get-role --role-name "%ROLE_NAME%" >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo     Role already exists, skipping creation.
) else (
    aws iam create-role ^
        --role-name "%ROLE_NAME%" ^
        --assume-role-policy-document "file://%TRUST_POLICY_FILE%" ^
        --description "Role used by Terraform to deploy Langfuse on ECS Fargate" ^
        --tags Key=Project,Value=langfuse Key=ManagedBy,Value=terraform
    if !ERRORLEVEL! NEQ 0 (
        echo ERROR: Failed to create role.
        del "%TRUST_POLICY_FILE%" 2>nul
        exit /b 1
    )
    echo     Created.
)

:: -------------------------------------------------------
:: 2. Create / update managed policy — networking & storage
:: -------------------------------------------------------
echo.
echo ==^> Creating managed policy: %POLICY_1_NAME%...
set "POLICY_1_ARN=arn:aws:iam::%ACCOUNT_ID%:policy/%POLICY_1_NAME%"

aws iam get-policy --policy-arn "%POLICY_1_ARN%" >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo     Policy exists. Creating a new version...
    call :delete_oldest_policy_version "%POLICY_1_ARN%"
    aws iam create-policy-version ^
        --policy-arn "%POLICY_1_ARN%" ^
        --policy-document "file://%SCRIPT_DIR%\policy-networking-storage.json" ^
        --set-as-default
    if !ERRORLEVEL! NEQ 0 (
        echo ERROR: Failed to update policy version.
        exit /b 1
    )
) else (
    aws iam create-policy ^
        --policy-name "%POLICY_1_NAME%" ^
        --policy-document "file://%SCRIPT_DIR%\policy-networking-storage.json" ^
        --description "Terraform: EC2/VPC, S3, ECR, EFS, ALB permissions for Langfuse" ^
        --tags Key=Project,Value=langfuse Key=ManagedBy,Value=terraform ^
        --query Policy.Arn --output text
    if !ERRORLEVEL! NEQ 0 (
        echo ERROR: Failed to create policy.
        exit /b 1
    )
    echo     Created: %POLICY_1_ARN%
)

:: -------------------------------------------------------
:: 3. Create / update managed policy — app services
:: -------------------------------------------------------
echo.
echo ==^> Creating managed policy: %POLICY_2_NAME%...
set "POLICY_2_ARN=arn:aws:iam::%ACCOUNT_ID%:policy/%POLICY_2_NAME%"

aws iam get-policy --policy-arn "%POLICY_2_ARN%" >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo     Policy exists. Creating a new version...
    call :delete_oldest_policy_version "%POLICY_2_ARN%"
    aws iam create-policy-version ^
        --policy-arn "%POLICY_2_ARN%" ^
        --policy-document "file://%SCRIPT_DIR%\policy-app-services.json" ^
        --set-as-default
    if !ERRORLEVEL! NEQ 0 (
        echo ERROR: Failed to update policy version.
        exit /b 1
    )
) else (
    aws iam create-policy ^
        --policy-name "%POLICY_2_NAME%" ^
        --policy-document "file://%SCRIPT_DIR%\policy-app-services.json" ^
        --description "Terraform: ECS, RDS, ElastiCache, IAM roles, AWS Backup for Langfuse" ^
        --tags Key=Project,Value=langfuse Key=ManagedBy,Value=terraform ^
        --query Policy.Arn --output text
    if !ERRORLEVEL! NEQ 0 (
        echo ERROR: Failed to create policy.
        exit /b 1
    )
    echo     Created: %POLICY_2_ARN%
)

:: -------------------------------------------------------
:: 4. Create / update managed policy — app services (part 2)
::
:: Split from POLICY_2 because a single managed policy document
:: cannot exceed AWS's 6144-character limit.
:: -------------------------------------------------------
echo.
echo ==^> Creating managed policy: %POLICY_3_NAME%...
set "POLICY_3_ARN=arn:aws:iam::%ACCOUNT_ID%:policy/%POLICY_3_NAME%"

aws iam get-policy --policy-arn "%POLICY_3_ARN%" >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo     Policy exists. Creating a new version...
    call :delete_oldest_policy_version "%POLICY_3_ARN%"
    aws iam create-policy-version ^
        --policy-arn "%POLICY_3_ARN%" ^
        --policy-document "file://%SCRIPT_DIR%\policy-app-services-2.json" ^
        --set-as-default
    if !ERRORLEVEL! NEQ 0 (
        echo ERROR: Failed to update policy version.
        exit /b 1
    )
) else (
    aws iam create-policy ^
        --policy-name "%POLICY_3_NAME%" ^
        --policy-document "file://%SCRIPT_DIR%\policy-app-services-2.json" ^
        --description "Terraform: Secrets Manager, Logs, Route53, CloudMap, AutoScaling for Langfuse" ^
        --tags Key=Project,Value=langfuse Key=ManagedBy,Value=terraform ^
        --query Policy.Arn --output text
    if !ERRORLEVEL! NEQ 0 (
        echo ERROR: Failed to create policy.
        exit /b 1
    )
    echo     Created: %POLICY_3_ARN%
)

:: -------------------------------------------------------
:: 5. Attach all three policies to the role
:: -------------------------------------------------------
echo.
echo ==^> Attaching policies to role...
aws iam attach-role-policy --role-name "%ROLE_NAME%" --policy-arn "%POLICY_1_ARN%"
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Failed to attach %POLICY_1_NAME%.
    exit /b 1
)
echo     Attached: %POLICY_1_NAME%

aws iam attach-role-policy --role-name "%ROLE_NAME%" --policy-arn "%POLICY_2_ARN%"
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Failed to attach %POLICY_2_NAME%.
    exit /b 1
)
echo     Attached: %POLICY_2_NAME%

aws iam attach-role-policy --role-name "%ROLE_NAME%" --policy-arn "%POLICY_3_ARN%"
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Failed to attach %POLICY_3_NAME%.
    exit /b 1
)
echo     Attached: %POLICY_3_NAME%

:: -------------------------------------------------------
:: 6. Cleanup temp file and print summary
:: -------------------------------------------------------
del "%TRUST_POLICY_FILE%" 2>nul

set "ROLE_ARN=arn:aws:iam::%ACCOUNT_ID%:role/%ROLE_NAME%"

echo.
echo ======================================================
echo  Setup complete!
echo ======================================================
echo.
echo  Role ARN:
echo    %ROLE_ARN%
echo.
echo  Next steps:
echo    1. Copy the Role ARN above
echo    2. Add to your terraform.tfvars:
echo.
echo         terraform_role_arn = "%ROLE_ARN%"
echo.
echo    3. Run Terraform:
echo         terraform init
echo         terraform plan
echo         terraform apply
echo ======================================================

endlocal
exit /b 0

:: -------------------------------------------------------
:: Subroutine: delete ALL non-default policy versions.
:: Fetches every version ID then attempts to delete each.
:: AWS silently rejects deletion of the default version,
:: so no JMESPath filtering is needed.
:: -------------------------------------------------------
:delete_oldest_policy_version
setlocal
set "PARN=%~1"
set "TMPFILE=%TEMP%\langfuse-policy-versions-%RANDOM%.txt"

aws iam list-policy-versions --policy-arn "%PARN%" --query "Versions[].VersionId" --output text > "%TMPFILE%" 2>nul

for /f "tokens=*" %%v in (%TMPFILE%) do (
    for %%i in (%%v) do (
        aws iam delete-policy-version --policy-arn "%PARN%" --version-id "%%i" >nul 2>&1
        echo     Deleted version: %%i
    )
)

del "%TMPFILE%" >nul 2>&1
endlocal
goto :eof
