# Declare the parameters accepted by the script.
param(
    # Allow -l as a shorter alias for -Port.
    [Alias("l")]

    # Reject port numbers outside the valid TCP port range.
    [ValidateRange(1, 65535)]

    # Store the local TCP listening port as a 32-bit integer.
    [int]$Port,

    # Allow -t as a shorter alias for -TargetHost.
    [Alias("t")]

    # Store the destination hostname or IP address as a string.
    [string]$TargetHost,

    # Allow -p as a shorter alias for -TargetPort.
    [Alias("p")]

    # Reject port numbers outside the valid TCP port range.
    [ValidateRange(1, 65535)]

    # Store the destination TCP port as a 32-bit integer.
    [int]$TargetPort,

    # Allow -c as a shorter alias for -Continuous.
    [Alias("c")]

    # Define a switch parameter. It is $true when -Continuous or -c is supplied and $false when the switch is omitted.
    [switch]$Continuous
)

#
# Display help if a mandatory flag is missing
#

# Validate the three values required to start the proxy.
#
# The condition succeeds if any of the following is true:
#   1. The listening port is zero or negative.
#   2. The target hostname is null, empty, or only whitespace.
#   3. The target port is zero or negative.
if (
    $Port -le 0 -or
    [string]::IsNullOrWhiteSpace($TargetHost) -or
    $TargetPort -le 0
) {
    # Retrieve the filename portion of the path used to invoke the script.
    #
    # $MyInvocation.MyCommand.Path contains the path of the currently executing script. Split-Path -Leaf removes the directory components.
    $scriptName = Split-Path -Leaf $MyInvocation.MyCommand.Path

    # If no script filename is available, use a stable fallback filename for the usage examples.
    if ([string]::IsNullOrWhiteSpace($scriptName)) {
        $scriptName = "ProxyShot.ps1"
    }

    # Print the command syntax.
    Write-Host ""
    Write-Host "Usage:"
    Write-Host "  .\$scriptName -l <listen port> -t <target> -p <target port> [-c]"
    Write-Host ""
    Write-Host "Flags:"
    Write-Host "  -l, -L    Port on which the proxy will listen. Required."
    Write-Host "  -t, -T    Target hostname or IP address. Required."
    Write-Host "  -p, -P    Target port to which traffic will be forwarded. Required."
    Write-Host "  -c, -C    Continuous mode. Continue accepting new connections"
    Write-Host "            after the current connection disconnects."
    Write-Host ""
    Write-Host "Example:"
    Write-Host "  .\$scriptName -l 1865 -t 192.168.0.122 -p 1337 -c"
    Write-Host ""

    # Terminate the script with a nonzero exit code to indicate that the required arguments were not provided correctly.
    exit 1
}

# Maintain the proxy's global stop state.
#
# This variable becomes $true when the user presses Q or when single-connection mode finishes its first connection.
$shouldStop = $false

# Construct a TCP listener.
#
# IPAddress.Any binds the listener to all IPv4 interfaces available to the local system. $Port supplies the local TCP port.
$listener = [System.Net.Sockets.TcpListener]::new(
    [System.Net.IPAddress]::Any,
    $Port
)

# Bind the listener and begin listening for inbound TCP connections.
$listener.Start()

# Report the local listening port and fixed destination endpoint.
Write-Host "Proxy listening on port $Port. Forwarding to ${TargetHost}:${TargetPort}"

# Report which connection-handling mode is active.
if ($Continuous) {
    # In continuous mode, the outer loop can accept another client after the current client disconnects.
    Write-Host "Continuous mode enabled."
}
else {
    # In single-connection mode, the proxy stops after the first accepted connection ends.
    Write-Host "Single-connection mode enabled."
}

# Tell the operator how to request a graceful shutdown.
Write-Host "Press Q to stop."

# Use a try/finally block so the listener is stopped even if an unhandled terminating error occurs inside the main loop.
try {
    # Continue accepting or servicing connections until the stop flag becomes $true.
    while (-not $shouldStop) {

        #
        # Check keyboard input
        #

        # Test whether a console key is waiting before attempting to read it.
        #
        # This prevents ReadKey from blocking the proxy while no key has been pressed.
        if ([Console]::KeyAvailable) {
            # Read the pending key.
            #
            # Passing $true prevents the key from being echoed to the console.
            $key = [Console]::ReadKey($true)

            # Treat either lowercase or uppercase Q as a shutdown request.
            if ($key.KeyChar -eq "q" -or $key.KeyChar -eq "Q") {
                Write-Host "Stopping proxy..."

                # Signal both the outer connection-acceptance loop and any active forwarding loop to stop.
                $shouldStop = $true

                # Leave the current outer-loop iteration immediately.
                break
            }
        }

        #
        # Don't block while waiting for connections
        #

        # Pending() reports whether a connection is already queued for acceptance. Checking it prevents AcceptTcpClient() from blocking.
        if (-not $listener.Pending()) {
            # Pause briefly to avoid continuously polling the listener and consuming an entire CPU core.
            Start-Sleep -Milliseconds 50

            # Restart the outer loop, including the keyboard check.
            continue
        }

        # Accept the next queued TCP connection.
        #
        # Because Pending() was checked first, this call should not wait indefinitely for a client to arrive.
        $client = $listener.AcceptTcpClient()

        # Initialize the outbound connection variable before entering the nested try block. This allows the finally block to test safely whether the target connection was created.
        $target = $null

        # Display the remote IP address and source port of the client.
        Write-Host "New client connected: $($client.Client.RemoteEndPoint)"

        # Handle the outbound connection and bidirectional forwarding.
        try {
            # Create a new outbound TCP connection to the configured target host and port.
            #
            # This constructor performs the connection attempt.
            $target = [System.Net.Sockets.TcpClient]::new(
                $TargetHost,
                $TargetPort
            )

            # Confirm the destination endpoint after the connection succeeds.
            Write-Host "Forwarding to ${TargetHost}:${TargetPort}"

            # Obtain a NetworkStream representing the accepted client socket.
            $clientStream = $client.GetStream()

            # Obtain a NetworkStream representing the outbound target socket.
            $targetStream = $target.GetStream()

            # Repeatedly copy available bytes in both directions until either endpoint disconnects or the operator presses Q.
            while (-not $shouldStop) {

                #
                # Check for stop key while forwarding
                #

                # Check for keyboard input without blocking network forwarding.
                if ([Console]::KeyAvailable) {
                    # Consume the key without displaying it.
                    $key = [Console]::ReadKey($true)

                    # Stop on either lowercase or uppercase Q.
                    if ($key.KeyChar -eq "q" -or $key.KeyChar -eq "Q") {
                        Write-Host "Stopping proxy..."

                        # Update the shared stop state so the outer loop also terminates.
                        $shouldStop = $true

                        # Leave the active forwarding loop.
                        break
                    }
                }

                #
                # Detect an orderly disconnect from the client
                #

                # Poll the client socket for readability without waiting.
                #
                # SelectRead can indicate either:
                #   1. Data is available to read.
                #   2. The remote endpoint has closed the connection.
                #
                # Checking Available distinguishes these cases. If the socket is readable but zero bytes are available, the connection is treated as closed.
                $clientDisconnected = (
                    $client.Client.Poll(
                        0,
                        [System.Net.Sockets.SelectMode]::SelectRead
                    ) -and
                    $client.Client.Available -eq 0
                )

                # End forwarding when the client has closed its connection.
                if ($clientDisconnected) {
                    Write-Host "Client disconnected."
                    break
                }

                #
                # Detect an orderly disconnect from the target
                #

                # Apply the same nonblocking disconnect test to the outbound target socket.
                $targetDisconnected = (
                    $target.Client.Poll(
                        0,
                        [System.Net.Sockets.SelectMode]::SelectRead
                    ) -and
                    $target.Client.Available -eq 0
                )

                # End forwarding when the target has closed its connection.
                if ($targetDisconnected) {
                    Write-Host "Target disconnected."
                    break
                }

                #
                # Client -> Target
                #

                # DataAvailable prevents Read() from blocking when the client has not supplied any bytes.
                if ($clientStream.DataAvailable) {
                    # Allocate an 8192-byte buffer for this read operation.
                    $buffer = New-Object byte[] 8192

                    # Read up to the full buffer length from the client stream.
                    #
                    # The return value is the actual number of bytes placed into the buffer.
                    $bytesRead = $clientStream.Read(
                        $buffer,
                        0,
                        $buffer.Length
                    )

                    # A stream read returning zero or fewer bytes is treated as the end of the client connection.
                    if ($bytesRead -le 0) {
                        Write-Host "Client disconnected."
                        break
                    }

                    # Write only the bytes actually read from the client to the target stream.
                    $targetStream.Write(
                        $buffer,
                        0,
                        $bytesRead
                    )

                    # Request that any buffered target-stream output be sent onward immediately.
                    $targetStream.Flush()
                }

                #
                # Target -> Client
                #

                # Check whether the target has bytes ready before calling Read(), preventing the read from blocking.
                if ($targetStream.DataAvailable) {
                    # Allocate a separate 8192-byte buffer for this target-to-client read operation.
                    $buffer = New-Object byte[] 8192

                    # Read up to 8192 bytes from the target stream.
                    $bytesRead = $targetStream.Read(
                        $buffer,
                        0,
                        $buffer.Length
                    )

                    # Treat a zero-length or negative-length result as termination of the target connection.
                    if ($bytesRead -le 0) {
                        Write-Host "Target disconnected."
                        break
                    }

                    # Forward the bytes received from the target to the client.
                    $clientStream.Write(
                        $buffer,
                        0,
                        $bytesRead
                    )

                    # Request immediate delivery of buffered client output.
                    $clientStream.Flush()
                }

                # Briefly yield between polling iterations to reduce CPU use.
                #
                # This also means the loop checks the streams and keyboard approximately every five milliseconds while active.
                Start-Sleep -Milliseconds 5
            }
        }
        catch {
            # Catch errors raised while connecting to the target, obtaining streams, reading, writing, or flushing.
            #
            # $_ represents the current error record.
            Write-Host "Error: $_"
        }
        finally {
            # This block runs whether forwarding ends normally or because an exception was caught.
            Write-Host "Closing connections."

            # Close the accepted client connection if it was created.
            if ($client) {
                $client.Close()
            }

            # Close the outbound target connection if its construction completed successfully.
            if ($target) {
                $target.Close()
            }
        }

        #
        # Without -c, stop after the first connection ends
        #

        # If continuous mode was not requested and shutdown was not already requested with Q, stop the proxy after the first connection ends.
        if (-not $Continuous -and -not $shouldStop) {
            Write-Host "Connection ended. Continuous mode was not enabled."

            # Cause the outer acceptance loop to terminate.
            $shouldStop = $true
        }
    }
}
finally {
    # Stop listening and release the listener's underlying socket.
    #
    # This runs after normal shutdown and after an unhandled terminating error inside the outer try block.
    $listener.Stop()

    # Confirm that listener cleanup has completed.
    Write-Host "Proxy stopped gracefully."
}