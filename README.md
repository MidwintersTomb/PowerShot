# PowerShot

![PowerShell logo with a single circuit on the left connecting to it and a single circuit exiting it on the right.  Below it is the word "PowerShot"](https://raw.githubusercontent.com/MidwintersTomb/MediaFiles/refs/heads/main/Pictures/PowerShot1.png)

## A PowerShell single port tunneling script

### Usage:

```powershell
  .\PowerShot.ps1 -l <listen port> -t <target> -p <target port> [-c]
```

### Flags:

```
  -l, -L    Port on which the proxy will listen. (REQUIRED)
  -t, -T    Target hostname or IP address. (REQUIRED)
  -p, -P    Target port to which traffic will be forwarded. (REQUIRED)
  -c, -C    Continuous mode. Continue accepting new connections after the current connection disconnects.
```

### Example:

```powershell
  .\PowerShot.ps1 -l 1865 -t 192.168.0.122 -p 1337 -c
```

## So what is this exactly?

After working on my [scripts for performing data exfil without using a specific protocol like SSH, SMB, etc.](https://github.com/MidwintersTomb/DataExfil), I took that knowledge and wrote a script that would forward a single port via PowerShell.  It worked, but was a little jank.  (It had issues detecting when a client disconnected.)  I then let the project sit for a quite a while due to life, work, etc. getting in the way.  Recently, I picked it back up and tossed it against a LLM to fix the disconnect detection, clean up my spaghetti code, and add annotations.  As in the past, working with a LLM can be exceedingly frustrating to get exactly what you want, and you end up learning in the process from wanting to strangle the screen.

## Advice

If you're running this through a remote shell or similar where you don't have a full fledged console, I'd recommend not using the `-c` flag, so it doesn't hang your session, as it's open on the system waiting for `Q` to be pressed.  (Unless you're fine with that, then, well, you do you, boo.)

As usual, do with it what you will, I'm not responsible for you doing something dumb with it.
