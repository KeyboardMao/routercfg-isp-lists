# Remove only the automatic updater and its scheduler.
# Active address lists and mangle routing policy are deliberately preserved.

{
    :local updaterName "routercfg-isp-list-update"
    :local updaterComment "routercfg: automatic disjoint ISP address-list updater"
    :local schedulerComment "routercfg: daily check for validated ISP address-list release"

    :if ([/system script job print count-only as-value where script=$updaterName] != 0) do={
        :error "ISP list updater remover: updater is currently running"
    }
    :if ([/system script print count-only as-value where name=$updaterName] > 1) do={
        :error "ISP list updater remover: duplicate managed scripts"
    }
    :if ([/system scheduler print count-only as-value where name=$updaterName] > 1) do={
        :error "ISP list updater remover: duplicate managed schedulers"
    }
    :if ([/system script print count-only as-value where name=$updaterName] = 1) do={
        :local script [/system script find where name=$updaterName]
        :if ([:tostr [/system script get $script comment]] != $updaterComment) do={
            :error "ISP list updater remover: script identity check failed"
        }
    }
    :if ([/system scheduler print count-only as-value where name=$updaterName] = 1) do={
        :local scheduler [/system scheduler find where name=$updaterName]
        :if ([:tostr [/system scheduler get $scheduler comment]] != $schedulerComment) do={
            :error "ISP list updater remover: scheduler identity check failed"
        }
        /system scheduler disable $scheduler
        /system scheduler remove $scheduler
    }
    /system script remove [find where name=$updaterName and comment=$updaterComment]
    /file remove [find where name="routercfg-isp-auto-a.rsc"]
    /file remove [find where name="routercfg-isp-auto-b.rsc"]

    :if ([/system script print count-only as-value where name=$updaterName] != 0) do={ :error "ISP list updater remover: script remains" }
    :if ([/system scheduler print count-only as-value where name=$updaterName] != 0) do={ :error "ISP list updater remover: scheduler remains" }
    :log warning "ISP list updater automation removed; active lists and mangle policy preserved"
    :put "Updater and scheduler removed. Current ISP lists and routing policy remain active."
}
