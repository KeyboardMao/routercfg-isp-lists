# Stop automatic updates and point the two affinity rules back to the retained
# 2026-09-17 static lists.  Auto A/B lists are kept inert for diagnosis.

{
    :local updaterName "routercfg-isp-list-update"
    :local updaterComment "routercfg: automatic disjoint ISP address-list updater"
    :local schedulerComment "routercfg: daily check for validated ISP address-list release"
    :local unicomRuleComment "routercfg ISP affinity: ordinary Unicom-only destination"
    :local mobileRuleComment "routercfg ISP affinity: ordinary Mobile-only destination"
    :local legacyUnicom "routercfg-isp-unicom-only-20260917"
    :local legacyMobile "routercfg-isp-mobile-only-20260917"

    :if ([/system script job print count-only as-value where script=$updaterName] != 0) do={
        :error "ISP list rollback: updater is currently running"
    }
    :if ([/system script print count-only as-value where name=$updaterName] > 1) do={
        :error "ISP list rollback: duplicate managed scripts"
    }
    :if ([/system scheduler print count-only as-value where name=$updaterName] > 1) do={
        :error "ISP list rollback: duplicate managed schedulers"
    }
    :if ([/system script print count-only as-value where name=$updaterName] = 1) do={
        :local managedScript [/system script find where name=$updaterName]
        :if ([:tostr [/system script get $managedScript comment]] != $updaterComment) do={
            :error "ISP list rollback: script identity check failed"
        }
    }
    :if ([/system scheduler print count-only as-value where name=$updaterName] = 1) do={
        :local managedScheduler [/system scheduler find where name=$updaterName]
        :if ([:tostr [/system scheduler get $managedScheduler comment]] != $schedulerComment) do={
            :error "ISP list rollback: scheduler identity check failed"
        }
    }
    :if ([/ip firewall address-list print count-only as-value where list=$legacyUnicom] != 1520) do={
        :error "ISP list rollback: retained Unicom legacy list is missing or incomplete"
    }
    :if ([/ip firewall address-list print count-only as-value where list=$legacyMobile] != 948) do={
        :error "ISP list rollback: retained Mobile legacy list is missing or incomplete"
    }
    :if ([/ip firewall mangle print count-only as-value where comment=$unicomRuleComment] != 1) do={
        :error "ISP list rollback: unique Unicom affinity rule not found"
    }
    :if ([/ip firewall mangle print count-only as-value where comment=$mobileRuleComment] != 1) do={
        :error "ISP list rollback: unique Mobile affinity rule not found"
    }

    :local unicomRule [/ip firewall mangle find where comment=$unicomRuleComment]
    :local mobileRule [/ip firewall mangle find where comment=$mobileRuleComment]
    :if (([:tostr [/ip firewall mangle get $unicomRule chain]] != "prerouting") || \
        ([:tostr [/ip firewall mangle get $unicomRule action]] != "mark-connection") || \
        ([:tostr [/ip firewall mangle get $unicomRule new-connection-mark]] != "conn_unicom") || \
        ([:tostr [/ip firewall mangle get $unicomRule disabled]] != "false")) do={
        :error "ISP list rollback: Unicom affinity rule identity changed"
    }
    :if (([:tostr [/ip firewall mangle get $mobileRule chain]] != "prerouting") || \
        ([:tostr [/ip firewall mangle get $mobileRule action]] != "mark-connection") || \
        ([:tostr [/ip firewall mangle get $mobileRule new-connection-mark]] != "conn_mobile") || \
        ([:tostr [/ip firewall mangle get $mobileRule disabled]] != "false")) do={
        :error "ISP list rollback: Mobile affinity rule identity changed"
    }
    /system scheduler disable [find where name=$updaterName and comment=$schedulerComment]

    :local priorUnicom [:tostr [/ip firewall mangle get $unicomRule dst-address-list]]
    :local priorMobile [:tostr [/ip firewall mangle get $mobileRule dst-address-list]]
    :onerror switchError in={
        /ip firewall mangle set $unicomRule dst-address-list=$legacyUnicom
        /ip firewall mangle set $mobileRule dst-address-list=$legacyMobile
    } do={
        /ip firewall mangle set $unicomRule dst-address-list=$priorUnicom
        /ip firewall mangle set $mobileRule dst-address-list=$priorMobile
        :error ("ISP list rollback: policy switch failed and was reverted: " . $switchError)
    }
    :if (([:tostr [/ip firewall mangle get $unicomRule dst-address-list]] != $legacyUnicom) || \
        ([:tostr [/ip firewall mangle get $mobileRule dst-address-list]] != $legacyMobile)) do={
        /ip firewall mangle set $unicomRule dst-address-list=$priorUnicom
        /ip firewall mangle set $mobileRule dst-address-list=$priorMobile
        :error "ISP list rollback: post-check failed and prior pair was restored"
    }

    :if ([/system scheduler print count-only as-value where name=$updaterName] = 1) do={
        /system scheduler remove [find where name=$updaterName and comment=$schedulerComment]
    }
    /system script remove [find where name=$updaterName and comment=$updaterComment]
    /file remove [find where name="routercfg-isp-auto-a.rsc"]
    /file remove [find where name="routercfg-isp-auto-b.rsc"]
    :if ([/system script print count-only as-value where name=$updaterName] != 0) do={
        :error "ISP list rollback: managed script remains"
    }
    :if ([/system scheduler print count-only as-value where name=$updaterName] != 0) do={
        :error "ISP list rollback: managed scheduler remains"
    }
    :log warning "ISP list automation rolled back to retained 2026-09-17 static lists"
    :put "Rollback complete: static 2026-09-17 lists are active; automatic updater removed."
}
