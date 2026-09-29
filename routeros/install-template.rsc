# RouterOS 7.24.4 installer for the automatic disjoint ISP list updater.
#
# BEFORE UPLOAD: replace the placeholder in both :local baseUrl assignments
# HTTPS GitHub Pages base URL that contains manifest.json and slot-a/b.rsc.
# Example: https://example.github.io/routeros-isp-lists
#
# The installer only creates one script and one DISABLED scheduler.  It does
# not download lists or change mangle rules until the operator manually runs
# the installed script.

{
    :log warning "routercfg ISP auto updater installer: start"

    :local baseUrl "BASE_URL_REPLACE_ME"
    :local updaterName "routercfg-isp-list-update"
    :local updaterComment "routercfg: automatic disjoint ISP address-list updater"
    :local schedulerComment "routercfg: daily check for validated ISP address-list release"
    :local unicomRuleComment "routercfg ISP affinity: ordinary Unicom-only destination"
    :local mobileRuleComment "routercfg ISP affinity: ordinary Mobile-only destination"

    :if ([:pick [:tostr [/system resource get version]] 0 6] != "7.24.4") do={
        :error "routercfg ISP auto updater: approved only for RouterOS 7.24.4"
    }
    :if ([:pick $baseUrl 0 8] != "https://") do={
        :error "routercfg ISP auto updater: replace the base URL placeholder with an HTTPS Pages URL"
    }
    :if ([:pick $baseUrl ([:len $baseUrl] - 1) [:len $baseUrl]] = "/") do={
        :error "routercfg ISP auto updater: base URL must not end with a slash"
    }
    :if ([/system script print count-only as-value where name=$updaterName] != 0) do={
        :error "routercfg ISP auto updater: managed script already exists"
    }
    :if ([/system scheduler print count-only as-value where name=$updaterName] != 0) do={
        :error "routercfg ISP auto updater: managed scheduler already exists"
    }
    :if ([/ip firewall mangle print count-only as-value where comment=$unicomRuleComment] != 1) do={
        :error "routercfg ISP auto updater: unique Unicom affinity rule not found"
    }
    :if ([/ip firewall mangle print count-only as-value where comment=$mobileRuleComment] != 1) do={
        :error "routercfg ISP auto updater: unique Mobile affinity rule not found"
    }
    :if ([/routing table print count-only as-value where name="to_unicom"] != 1) do={
        :error "routercfg ISP auto updater: to_unicom table missing or duplicated"
    }
    :if ([/routing table print count-only as-value where name="to_mobile"] != 1) do={
        :error "routercfg ISP auto updater: to_mobile table missing or duplicated"
    }

    :local unicomRule [/ip firewall mangle find where comment=$unicomRuleComment]
    :local mobileRule [/ip firewall mangle find where comment=$mobileRuleComment]
    :if (([:tostr [/ip firewall mangle get $unicomRule chain]] != "prerouting") || \
        ([:tostr [/ip firewall mangle get $unicomRule action]] != "mark-connection") || \
        ([:tostr [/ip firewall mangle get $unicomRule new-connection-mark]] != "conn_unicom") || \
        ([:tostr [/ip firewall mangle get $unicomRule disabled]] != "false")) do={
        :error "routercfg ISP auto updater: Unicom affinity rule differs from the approved layout"
    }
    :if (([:tostr [/ip firewall mangle get $mobileRule chain]] != "prerouting") || \
        ([:tostr [/ip firewall mangle get $mobileRule action]] != "mark-connection") || \
        ([:tostr [/ip firewall mangle get $mobileRule new-connection-mark]] != "conn_mobile") || \
        ([:tostr [/ip firewall mangle get $mobileRule disabled]] != "false")) do={
        :error "routercfg ISP auto updater: Mobile affinity rule differs from the approved layout"
    }

    /system script add name=$updaterName policy=ftp,read,write,test,policy dont-require-permissions=no comment=$updaterComment source={
        :if ([/system script job print count-only as-value where script=[:jobname]] > 1) do={
            :error "ISP list updater: another instance is already running"
        }

        :local baseUrl "BASE_URL_REPLACE_ME"
        :local expectedRouterVersion "7.24.4"
        :local schema "routercfg.isp-affinity-lists"
        :local updaterName "routercfg-isp-list-update"
        :local updaterComment "routercfg: automatic disjoint ISP address-list updater"
        :local unicomRuleComment "routercfg ISP affinity: ordinary Unicom-only destination"
        :local mobileRuleComment "routercfg ISP affinity: ordinary Mobile-only destination"
        :local legacyUnicom "routercfg-isp-unicom-only-20260917"
        :local legacyMobile "routercfg-isp-mobile-only-20260917"
        :local aUnicom "routercfg-isp-unicom-auto-a"
        :local aMobile "routercfg-isp-mobile-auto-a"
        :local bUnicom "routercfg-isp-unicom-auto-b"
        :local bMobile "routercfg-isp-mobile-auto-b"

        :log info "ISP list updater: checking manifest"

        :if ([:pick [:tostr [/system resource get version]] 0 6] != $expectedRouterVersion) do={
            :error ("ISP list updater: RouterOS version is no longer approved; expected " . $expectedRouterVersion)
        }
        :if ([:pick $baseUrl 0 8] != "https://") do={
            :error "ISP list updater: invalid HTTPS base URL"
        }
        :if ([/system script print count-only as-value where name=$updaterName and comment=$updaterComment] != 1) do={
            :error "ISP list updater: managed script identity check failed"
        }
        :if ([/ip firewall mangle print count-only as-value where comment=$unicomRuleComment] != 1) do={
            :error "ISP list updater: unique Unicom affinity rule not found"
        }
        :if ([/ip firewall mangle print count-only as-value where comment=$mobileRuleComment] != 1) do={
            :error "ISP list updater: unique Mobile affinity rule not found"
        }
        :if ([/routing table print count-only as-value where name="to_unicom"] != 1) do={
            :error "ISP list updater: to_unicom table missing or duplicated"
        }
        :if ([/routing table print count-only as-value where name="to_mobile"] != 1) do={
            :error "ISP list updater: to_mobile table missing or duplicated"
        }

        :local unicomRule [/ip firewall mangle find where comment=$unicomRuleComment]
        :local mobileRule [/ip firewall mangle find where comment=$mobileRuleComment]
        :if (([:tostr [/ip firewall mangle get $unicomRule chain]] != "prerouting") || \
            ([:tostr [/ip firewall mangle get $unicomRule action]] != "mark-connection") || \
            ([:tostr [/ip firewall mangle get $unicomRule new-connection-mark]] != "conn_unicom") || \
            ([:tostr [/ip firewall mangle get $unicomRule disabled]] != "false")) do={
            :error "ISP list updater: Unicom affinity rule identity changed"
        }
        :if (([:tostr [/ip firewall mangle get $mobileRule chain]] != "prerouting") || \
            ([:tostr [/ip firewall mangle get $mobileRule action]] != "mark-connection") || \
            ([:tostr [/ip firewall mangle get $mobileRule new-connection-mark]] != "conn_mobile") || \
            ([:tostr [/ip firewall mangle get $mobileRule disabled]] != "false")) do={
            :error "ISP list updater: Mobile affinity rule identity changed"
        }

        :local activeUnicom [:tostr [/ip firewall mangle get $unicomRule dst-address-list]]
        :local activeMobile [:tostr [/ip firewall mangle get $mobileRule dst-address-list]]
        :local activeSlot ""
        :if (($activeUnicom = $aUnicom) && ($activeMobile = $aMobile)) do={ :set activeSlot "a" }
        :if (($activeUnicom = $bUnicom) && ($activeMobile = $bMobile)) do={ :set activeSlot "b" }
        :if (($activeUnicom = $legacyUnicom) && ($activeMobile = $legacyMobile)) do={ :set activeSlot "legacy" }
        :if ($activeSlot = "") do={
            :error ("ISP list updater: Unicom/Mobile rules do not reference one approved pair; values=" . $activeUnicom . "," . $activeMobile)
        }

        :local manifestResult
        :onerror fetchError in={
            :set manifestResult [/tool fetch url=($baseUrl . "/manifest.json") output=user as-value \
                check-certificate=yes-without-crl http-max-redirect-count=2 duration=30s]
        } do={
            :error ("ISP list updater: manifest fetch failed: " . $fetchError)
        }
        :if ([:tostr ($manifestResult->"status")] != "finished") do={
            :error "ISP list updater: manifest fetch did not finish"
        }
        :local manifestText [:tostr ($manifestResult->"data")]
        :if (([:len $manifestText] < 100) || ([:len $manifestText] > 4096)) do={
            :error ("ISP list updater: manifest size is invalid: " . [:len $manifestText])
        }
        :local manifest
        :onerror jsonError in={
            :set manifest [:deserialize from=json value=$manifestText options=json.no-string-conversion]
        } do={
            :error ("ISP list updater: manifest JSON is invalid: " . $jsonError)
        }

        :if ([:tostr ($manifest->"schema")] != $schema) do={ :error "ISP list updater: manifest schema mismatch" }
        :if ([:tonum ($manifest->"schema_version")] != 1) do={ :error "ISP list updater: manifest version mismatch" }
        :local version [:tostr ($manifest->"version")]
        :local marker [:tostr ($manifest->"marker")]
        :if (([:len $version] != 16) || ($marker != ("routercfg-auto:" . $version))) do={
            :error "ISP list updater: manifest release identity is invalid"
        }
        :local listMeta ($manifest->"lists")
        :local unicomMeta ($listMeta->"unicom")
        :local mobileMeta ($listMeta->"mobile")
        :local expectedUnicom [:tonum ($unicomMeta->"count")]
        :local expectedMobile [:tonum ($mobileMeta->"count")]
        :if (($expectedUnicom < 500) || ($expectedUnicom > 5000)) do={
            :error ("ISP list updater: unsafe Unicom count in manifest: " . $expectedUnicom)
        }
        :if (($expectedMobile < 300) || ($expectedMobile > 4000)) do={
            :error ("ISP list updater: unsafe Mobile count in manifest: " . $expectedMobile)
        }

        :local alreadyCurrent false
        :if ($activeSlot != "legacy") do={
            :if (([/ip firewall address-list print count-only as-value where list=$activeUnicom] = $expectedUnicom) && \
                ([/ip firewall address-list print count-only as-value where list=$activeMobile] = $expectedMobile) && \
                ([/ip firewall address-list print count-only as-value where list=$activeUnicom and comment=$marker] = 1) && \
                ([/ip firewall address-list print count-only as-value where list=$activeMobile and comment=$marker] = 1)) do={
                :set alreadyCurrent true
            }
        }

        :if ($alreadyCurrent = true) do={
            :log info ("ISP list updater: already current; slot=" . $activeSlot . " version=" . $version)
        } else={
            :local targetSlot "a"
            :local targetUnicom $aUnicom
            :local targetMobile $aMobile
            :if ($activeSlot = "a") do={
                :set targetSlot "b"
                :set targetUnicom $bUnicom
                :set targetMobile $bMobile
            }

            :local slots ($manifest->"slots")
            :local slotMeta
            :local expectedFile "slot-a.rsc"
            :if ($targetSlot = "a") do={ :set slotMeta ($slots->"a") }
            :if ($targetSlot = "b") do={
                :set slotMeta ($slots->"b")
                :set expectedFile "slot-b.rsc"
            }
            :local remoteFile [:tostr ($slotMeta->"file")]
            :local expectedBytes [:tonum ($slotMeta->"bytes")]
            :if ($remoteFile != $expectedFile) do={ :error "ISP list updater: unexpected payload filename" }
            :if (($expectedBytes < 100000) || ($expectedBytes > 2000000)) do={
                :error ("ISP list updater: unsafe payload size in manifest: " . $expectedBytes)
            }

            :local temporaryFile ("routercfg-isp-auto-" . $targetSlot . ".rsc")
            /file remove [find where name=$temporaryFile]
            :local payloadResult
            :onerror payloadFetchError in={
                :set payloadResult [/tool fetch url=($baseUrl . "/" . $remoteFile) dst-path=$temporaryFile as-value \
                    check-certificate=yes-without-crl http-max-redirect-count=2 duration=2m]
            } do={
                /file remove [find where name=$temporaryFile]
                :error ("ISP list updater: payload fetch failed: " . $payloadFetchError)
            }
            :if ([:tostr ($payloadResult->"status")] != "finished") do={
                /file remove [find where name=$temporaryFile]
                :error "ISP list updater: payload fetch did not finish"
            }
            :if ([/file print count-only as-value where name=$temporaryFile] != 1) do={
                :error "ISP list updater: downloaded payload file is missing"
            }
            :local downloadedFile [/file find where name=$temporaryFile]
            :local downloadedBytes [:tonum [/file get $downloadedFile size]]
            :if ($downloadedBytes != $expectedBytes) do={
                /file remove $downloadedFile
                :error ("ISP list updater: payload size mismatch; expected=" . $expectedBytes . " actual=" . $downloadedBytes)
            }

            :onerror importError in={
                /import file-name=$temporaryFile
            } do={
                /file remove [find where name=$temporaryFile]
                :error ("ISP list updater: inactive slot import failed: " . $importError)
            }

            :if (([/ip firewall address-list print count-only as-value where list=$targetUnicom] != $expectedUnicom) || \
                ([/ip firewall address-list print count-only as-value where list=$targetMobile] != $expectedMobile) || \
                ([/ip firewall address-list print count-only as-value where list=$targetUnicom and comment=$marker] != 1) || \
                ([/ip firewall address-list print count-only as-value where list=$targetMobile and comment=$marker] != 1)) do={
                /file remove [find where name=$temporaryFile]
                :error "ISP list updater: inactive slot post-import validation failed; active slot was preserved"
            }

            # Re-read the live rules immediately before switching.  This stops
            # the update if an administrator changed either rule mid-run.
            :if (([:tostr [/ip firewall mangle get $unicomRule dst-address-list]] != $activeUnicom) || \
                ([:tostr [/ip firewall mangle get $mobileRule dst-address-list]] != $activeMobile)) do={
                /file remove [find where name=$temporaryFile]
                :error "ISP list updater: policy rules changed during update; active slot was preserved"
            }

            :onerror switchError in={
                /ip firewall mangle set $unicomRule dst-address-list=$targetUnicom
                /ip firewall mangle set $mobileRule dst-address-list=$targetMobile
            } do={
                /ip firewall mangle set $unicomRule dst-address-list=$activeUnicom
                /ip firewall mangle set $mobileRule dst-address-list=$activeMobile
                /file remove [find where name=$temporaryFile]
                :error ("ISP list updater: policy switch failed and was rolled back: " . $switchError)
            }

            :if (([:tostr [/ip firewall mangle get $unicomRule dst-address-list]] != $targetUnicom) || \
                ([:tostr [/ip firewall mangle get $mobileRule dst-address-list]] != $targetMobile)) do={
                /ip firewall mangle set $unicomRule dst-address-list=$activeUnicom
                /ip firewall mangle set $mobileRule dst-address-list=$activeMobile
                /file remove [find where name=$temporaryFile]
                :error "ISP list updater: policy post-check failed and was rolled back"
            }

            /file remove [find where name=$temporaryFile]
            :log warning ("ISP list updater: switched from " . $activeSlot . " to " . $targetSlot . "; version=" . $version . "; Unicom=" . $expectedUnicom . "; Mobile=" . $expectedMobile)
        }
    }

    /system scheduler add name=$updaterName interval=1d start-time=00:10:00 disabled=yes \
        policy=ftp,read,write,test,policy comment=$schedulerComment on-event=$updaterName

    :if ([/system script print count-only as-value where name=$updaterName and comment=$updaterComment] != 1) do={
        :error "routercfg ISP auto updater: script post-check failed"
    }
    :if ([/system scheduler print count-only as-value where name=$updaterName and comment=$schedulerComment] != 1) do={
        :error "routercfg ISP auto updater: scheduler post-check failed"
    }
    :local scheduler [/system scheduler find where name=$updaterName and comment=$schedulerComment]
    :if ([:tostr [/system scheduler get $scheduler disabled]] != "true") do={
        :error "routercfg ISP auto updater: scheduler was not installed disabled"
    }

    :log warning "routercfg ISP auto updater installer: complete; scheduler remains disabled"
    :put "ISP auto updater installed. Scheduler is DISABLED. Run /system script run routercfg-isp-list-update manually, validate, then enable the scheduler."
}
