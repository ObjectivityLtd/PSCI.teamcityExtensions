<#
The MIT License (MIT)

Copyright (c) 2015 Objectivity Bespoke Software Specialists

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
#>

function Wait-JMeter {

     <#
    .SYNOPSIS
    Waits until JMeter process spawned by Start-JMeter function finishes and validates JTL file is generated.
    
    .PARAMETER JMeterPid
    Process id of running JMeter. Must specify either this parameter or JMeterPidFile.
    
    .PARAMETER JMeterDir
    Path to root JMeter directory.

    .PARAMETER JMeterNonGUIPort
    The port where jmeter in non-GUI mode is listening on.

    .PARAMETER JMeterPidFile
    Path to a file containing running JMeter process id. Must specify either this parameter or JMeterPid.

    .PARAMETER JtlOutputFile
    Output file that will be created by JMeter (JTL).

    .PARAMETER StdOutFile
    File containing stdout generated by jmeter.bat.

    .PARAMETER StdErrFile
    File containing stderr generated by jmeter.bat.

    .PARAMETER TimeoutInSeconds
    Maximum time to wait before jmeter process is killed.

    .PARAMETER ShutdownMode
    The mode that should be used to kill JMeter process. Available options:
        - 'KillProcess' kills the processs explicitly
        - 'SendShutdownMessage' run the Shutdown client to stop a non-GUI instance gracefully
        - 'SendStopTestNowMessage' run the Shutdown client to stop a non-GUI instance abruptly

    .PARAMETER KillAfterTimeout
    If specified then the JMeter process is killed once $TimeoutInSeconds expires.

    .OUTPUTS
    True if JMeter process is still running, false otherwise.

    .EXAMPLE
    Wait-JMeter -JMeterPidFile 'f:\jmeter_pid' -JtlOutputFile "c:\workspace\test.jtl" -StdOutFile "f:\jmeter-stdout.txt" -StdErrFile "f:\jmeter-stderr.txt"
    #>

    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory=$false)]
        [int]
        $JMeterPid,

        [Parameter(Mandatory=$false)]
        [string]
        $JMeterPidFile,

        [Parameter(Mandatory=$false)]
        [string]
        $JMeterDir,

        [Parameter(Mandatory=$false)]
        [int]
        $JMeterNonGUIPort = 4445,

        [Parameter(Mandatory=$true)]
        [string]
        $JtlOutputFile,

        [Parameter(Mandatory=$false)]
        [string]
        $StdOutFile,

        [Parameter(Mandatory=$false)]
        [string]
        $StdErrFile,

        [Parameter(Mandatory=$false)]
        [int]
        $TimeoutInSeconds = 7200,

        [Parameter(Mandatory=$false)]
        [ValidateSet("KillProcess", "SendShutdownMessage", "SendStopTestNowMessage")]
        [string]
        $ShutdownMode = "KillProcess",

        [Parameter(Mandatory=$false)]
        [switch]
        $KillAfterTimeout
    )

    if (!$JMeterPid -and !$JMeterPidFile) {
        Write-Log -Critical 'Please specify one of $JMeterPid or $JMeterPidFile parameters.'
    }

    if (!$JMeterPid -and $JMeterPidFile) {
        if (!(Test-Path -LiteralPath $JMeterPidFile)) {
            Write-Log -Critical "No JMeter Pid file at '$JMeterPidFile'. Please investigate why Start-JMeter has not created it."
        }
        $JMeterPid = Get-Content -Path $JMeterPidFile -ReadCount 1
    }

    Write-Log -Info "Waiting for JMeter process (pid = $JMeterPid) to finish (timeout = $TimeoutInSeconds s)."

    $process = Get-Process -Id $JMeterPid -ErrorAction SilentlyContinue
    if (!$process) {
        Write-JMeterStdOutAndStdErr -StdOutFile $StdOutFile -StdErrFile $StdErrFile
        Test-JMeterSuccess -JtlOutputFile $JtlOutputFile
        return $false
    }

    Write-ProgressExternal -Message 'Waiting for JMeter'
    # todo: add JMeter real-time logging
    if (!$process.WaitForExit($TimeoutInSeconds * 1000)) {
        if ($KillAfterTimeout) {
            if ($ShutdownMode -eq "KillProcess") {
                Stop-ProcessForcefully -Process $process -KillTimeoutInSeconds 1
                Write-ProgressExternal -Message ''
                Write-Log -Critical "JMeter process has not finished after $TimeoutInSeconds s and has been killed."
            } elseif (!(Test-Path -LiteralPath $JMeterDir)) {
                Write-Log -Warn "Cannot find JMeter directory at '$JMeterDir'. JMeter process will be stopped in 'KillProcess' mode instead of '$ShutdownMode'"
                Stop-ProcessForcefully -Process $process -KillTimeoutInSeconds 1
                Write-ProgressExternal -Message ''
                Write-Log -Critical "JMeter process has not finished after $TimeoutInSeconds s and has been killed."
            } else {
                $javaPath = "java.exe"
                if ($ShutdownMode -eq "SendShutdownMessage") {
                    $message = "Shutdown"
                } else {
                    $message = "StopTestNow"
                }

                $apacheJMeterJarPath = Join-Path -Path $JMeterDir -ChildPath "bin\ApacheJMeter.jar"
                $cmdArgs += "-cp $apacheJMeterJarPath org.apache.jmeter.util.ShutdownClient $message $JMeterNonGUIPort"
                Write-Log -Info "JMeter process has not finished after $TimeoutInSeconds s - sending '$message' message..."
                [void](Start-ExternalProcess -Command $javaPath -ArgumentList $cmdArgs)

                # wait additional minute for shutdown
                $killTimeout = 60
                if (!$process.WaitForExit($killTimeout * 1000)) {				
                    Write-Log -Info "JMeter process is still running after $killTimeout s - killing."
                    Stop-ProcessForcefully -Process $process -KillTimeoutInSeconds $killTimeout
                }
                Write-Log -Info "JMeter process has been stopped."
            }
        } else {
            Write-ProgressExternal -Message ''
            Write-Log -Info "JMeter process still running after $TimeoutInSeconds s."
            return $true
        }
    }

    Write-ProgressExternal -Message ''

    Write-JMeterStdOutAndStdErr -StdOutFile $StdOutFile -StdErrFile $StdErrFile
    Test-JMeterSuccess -JtlOutputFile $JtlOutputFile

    return $false

}

function Stop-ProcessForcefully {

    <#
    .SYNOPSIS
    Kills process forcefully along with its children.
    
    .PARAMETER Process
    Process object.

    .PARAMETER KillTimeoutInSeconds
    Time to wait for process before killing it.
    
    .EXAMPLE
    Stop-ProcessForcefully -Process $process
    #>

	[CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory=$true)]
        [object]
        $Process,

        [Parameter(Mandatory=$true)]
        [int]
        $KillTimeoutInSeconds
    )
	
	$childProcesses = Get-WmiObject -Class Win32_Process -Filter "ParentProcessID=$($Process.Id)" | Select-Object -ExpandProperty ProcessID
	
	try { 
		if ($childProcesses) {
			Write-Log -Info "Killing child processes: $childProcesses"
			Stop-Process -Id $childProcesses -Force
		} else {
			Write-Log -Info "No child processes for pid $($Process.Id)"
		}
        Write-Log -Info "Killing process $($Process.Id)"
		$Process.Kill()
	} catch {
		Write-Log -Warn "Kill method thrown exception: $_ - waiting for exit."
	}
	if (!$Process.WaitForExit($KillTimeoutInSeconds * 1000)) {
		Write-Log -Critical "Cannot kill process (pid $($Process.Id)) - still running after $($KillTimeoutInSeconds * 1000 * 2) s"
	}
    Write-Log -Info "Process $($Process.Id) killed along with its children."
}

function Test-JMeterSuccess {

    <#
    .SYNOPSIS
    Checks whether JMeter finished successfully by checking if .jtl file has been generated.
    
    .PARAMETER JtlOutputFile
    Output file that should be created by JMeter (JTL).
    
    .EXAMPLE
    Test-JMeterSuccess -JtlOutputFile $JtlOutputFile
    #>

    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory=$true)]
        [string]
        $JtlOutputFile
    )

    if (Test-Path -LiteralPath $JtlOutputFile) {
        Write-Log -Info "JMeter process finished and generated jtl file at '$JtlOutputFile'." -Emphasize
        return
    } else {
        Write-Log -Critical "JMeter process finished but not generated jtl file at '$JtlOutputFile'. Please review stdout/stderr messages which should be logged above."
    }
}

function Write-JMeterStdOutAndStdErr {

    <#
    .SYNOPSIS
    Writes JMeter stdout / stderr files to stdout.
    
    .PARAMETER StdOutFile
    File containing stdout generated by jmeter.bat.

    .PARAMETER StdErrFile
    File containing stderr generated by jmeter.bat.
    
    .EXAMPLE
    Write-JMeterStdOutAndStdErr -StdOutFile $StdOutFile -StdErrFile $StdErrFile
    #>

    [CmdletBinding()]
    [OutputType([void])]
    param(
        [Parameter(Mandatory=$false)]
        [string]
        $StdOutFile,

        [Parameter(Mandatory=$false)]
        [string]
        $StdErrFile
    )

    if ($StdOutFile) {
        Write-Log -Info "JMeter stdout file contents ('$StdOutFile'):" -Emphasize
        Get-Content -Path $StdOutFile -ReadCount 0 | Foreach-Object { Write-Log -Info $_ }
    }

    if ($StdErrFile) {
        Write-Log -Info "JMeter stderr file contents ('$StdErrFile'):" -Emphasize
        Get-Content -Path $StdErrFile -ReadCount 0 | Foreach-Object { Write-Log -Info $_ }
    }


}