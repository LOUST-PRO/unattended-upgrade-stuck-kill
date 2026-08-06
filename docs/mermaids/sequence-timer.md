```mermaid
sequenceDiagram
    participant Timer as systemd timer
    participant Service as systemd service
    participant Script as stuck-kill.sh
    participant PSI as /proc/pressure/io
    participant Log as unattended-upgrades.log
    participant Proc as /proc/PID

    Timer->>Service: OnCalendar=*-*-* 05:10:00
    activate Service
    Service->>Script: ExecStart=/usr/local/sbin/...sh
    activate Script

    Script->>Script: read env (UA_STUCK_*)
    Script->>Script: setup LOG_DIR (system or user)
    Script->>Script: SELF_PID = $$

    Script->>Script: spawn self_test sentinel
    Script->>Proc: bash exec -a name sleep 600
    Proc-->>Script: PID alive
    Script->>Script: pgrep -af marker → visible
    Script->>Script: kill sentinel + verify filter
    Script->>Script: PASS or FAIL

    alt self-test FAIL
        Script-->>Service: exit 1
        deactivate Script
        Service-->>Timer: status=1 (no retry)
    else self-test PASS
        Script->>PSI: cat /proc/pressure/io
        PSI-->>Script: avg10=...

        alt io.full > threshold
            Script->>Script: log skip-busy
            Script-->>Service: exit 0
        else io.full ok
            Script->>Script: check rate-limit file

            alt rate-limited
                Script->>Script: log skip-ratelimit
                Script-->>Service: exit 0
            else rate-limit ok
                Script->>Log: tail -n 200
                Log-->>Script: 200 lines

                alt deny-log regex match
                    Script->>Script: log skip-deny-log
                    Script-->>Service: exit 0
                else deny-log no match
                    Script->>Proc: pgrep -af unattended-upgrade
                    Proc-->>Script: PID list

                    loop for each PID
                        Script->>Proc: read cmdline (tr '\0' ' ')
                        alt ALLOWLIST match
                            Script->>Script: log skip-pid (allowlist)
                        else no match
                            Script->>Proc: read /proc/PID/stat (etime, pcpu)
                            Script->>Proc: read /proc/PID/io (read_bytes)

                            Script->>Script: 3-criteria test
                            alt stuck
                                Script->>Proc: kill -TERM
                                Proc-->>Script: 30s grace
                                alt still alive
                                    Script->>Proc: kill -9
                                end
                                Script->>Script: log kill + record rate-limit
                            else not stuck
                                Script->>Script: log skip-pid (not-stuck)
                            end
                        end
                    end

                    Script-->>Service: exit 0
                end
            end
        end
    end

    deactivate Script
    deactivate Service
```
