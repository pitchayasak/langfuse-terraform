@echo off
:: Deletes the Langfuse Terraform IAM role and both managed policies.
:: Run this AFTER destroying Terraform resources (terraform destroy).
::
:: Usage:
::   iam-setup\delete-role.cmd [role-name]
::
:: Default role name: langfuse-terraform-deployer

setlocal EnableDelayedExpansion

set "ROLE_NAME=%~1"
if "%ROLE_NAME%"=="" set "ROLE_NAME=langfuse-terraform-deployer"

set "POLICY_1_NAME=langfuse-terraform-networking-storage"
set "POLICY_2_NAME=langfuse-terraform-app-services"

:: -------------------------------------------------------
:: Get account ID
:: -------------------------------------------------------
echo.
echo ==^> Getting current caller identity...
for /f "delims=" %%i in ('aws sts get-caller-identity --query Account --output text') do set "ACCOUNT_ID=%%i"
if "%ACCOUNT_ID%"=="" (
    echo ERROR: Could not retrieve AWS account ID. Check your AWS credentials.
    exit /b 1
)
echo     Account : %ACCOUNT_ID%

set "POLICY_1_ARN=arn:aws:iam::%ACCOUNT_ID%:policy/%POLICY_1_NAME%"
set "POLICY_2_ARN=arn:aws:iam::%ACCOUNT_ID%:policy/%POLICY_2_NAME%"
set "ROLE_ARN=arn:aws:iam::%ACCOUNT_ID%:role/%ROLE_NAME%"

echo.
echo  Will delete:
echo    Role    : %ROLE_ARN%
echo    Policy  : %POLICY_1_ARN%
echo    Policy  : %POLICY_2_ARN%
echo.
set /p "CONFIRM=Type YES to confirm: "
if /i not "%CONFIRM%"=="YES" (
    echo Cancelled.
    exit /b 0
)

:: -------------------------------------------------------
:: 1. Detach policies from role
:: -------------------------------------------------------
echo.
echo ==^> Detaching policies from role...

aws iam get-role --role-name "%ROLE_NAME%" >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo     Role does not exist, skipping detach.
    goto :delete_policies
)

aws iam detach-role-policy --role-name "%ROLE_NAME%" --policy-arn "%POLICY_1_ARN%" >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo     Detached: %POLICY_1_NAME%
) else (
    echo     %POLICY_1_NAME% was not attached ^(skipping^).
)

aws iam detach-role-policy --role-name "%ROLE_NAME%" --policy-arn "%POLICY_2_ARN%" >nul 2>&1
if %ERRORLEVEL% EQU 0 (
    echo     Detached: %POLICY_2_NAME%
) else (
    echo     %POLICY_2_NAME% was not attached ^(skipping^).
)

:: -------------------------------------------------------
:: 2. Delete the role
:: -------------------------------------------------------
echo.
echo ==^> Deleting IAM role: %ROLE_NAME%...
aws iam delete-role --role-name "%ROLE_NAME%"
if %ERRORLEVEL% EQU 0 (
    echo     Deleted.
) else (
    echo ERROR: Failed to delete role. It may still have inline policies or instance profiles attached.
    exit /b 1
)

:: -------------------------------------------------------
:: 3. Delete all versions of each policy, then the policy
:: -------------------------------------------------------
:delete_policies
echo.
echo ==^> Deleting managed policy: %POLICY_1_NAME%...
call :delete_policy "%POLICY_1_ARN%"

echo.
echo ==^> Deleting managed policy: %POLICY_2_NAME%...
call :delete_policy "%POLICY_2_ARN%"

echo.
echo ======================================================
echo  Done. Role and policies deleted.
echo ======================================================
endlocal
exit /b 0

:: -------------------------------------------------------
:: Subroutine: delete all non-default versions, then policy
:: -------------------------------------------------------
:delete_policy
setlocal
set "PARN=%~1"

aws iam get-policy --policy-arn "%PARN%" >nul 2>&1
if %ERRORLEVEL% NEQ 0 (
    echo     Policy does not exist, skipping.
    endlocal
    goto :eof
)

:: Delete all versions (AWS silently rejects deletion of the default version)
set "TMPFILE=%TEMP%\langfuse-del-versions-%RANDOM%.txt"
aws iam list-policy-versions --policy-arn "%PARN%" --query "Versions[].VersionId" --output text > "%TMPFILE%" 2>nul
for /f "tokens=*" %%v in (%TMPFILE%) do (
    for %%w in (%%v) do (
        aws iam delete-policy-version --policy-arn "%PARN%" --version-id "%%w" >nul 2>&1
        echo     Deleted version: %%w
    )
)
del "%TMPFILE%" >nul 2>&1

aws iam delete-policy --policy-arn "%PARN%"
if %ERRORLEVEL% EQU 0 (
    echo     Deleted.
) else (
    echo ERROR: Failed to delete policy %PARN%.
)
endlocal
goto :eof
