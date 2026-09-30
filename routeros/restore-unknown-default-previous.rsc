# Restore the exact pre-migration unknown-destination mode recorded in the
# managed fallback rule comment by set-unknown-default-mobile.rsc.

{
    :onerror caughtError in={
    :log warning "routercfg unknown-default-Mobile rollback: start"

    # ROUTEROS_COMPATIBILITY_POLICY_BEGIN
    :local routerVersion [:tostr [/system resource get version]]
    :local minimumRouterVersion "7.24.4"
    :local supportedMajor 7
    :local channelStart [:find $routerVersion " "]
    :if ([:typeof $channelStart] = "nil") do={
        :error ("routercfg unknown-default-Mobile rollback: malformed RouterOS version: " . $routerVersion)
    }
    :local numericVersion [:pick $routerVersion 0 $channelStart]
    :local versionChannel [:pick $routerVersion ($channelStart + 1) [:len $routerVersion]]
    :if (($numericVersion ~ "^[0-9]+\\.[0-9]+\\.[0-9]+$") = false) do={
        :error ("routercfg unknown-default-Mobile rollback: malformed RouterOS version: " . $routerVersion)
    }
    :if (($versionChannel != "(stable)") && ($versionChannel != "(long-term)")) do={
        :error ("routercfg unknown-default-Mobile rollback: unsupported RouterOS channel: " . $versionChannel)
    }
    :local firstDot [:find $numericVersion "."]
    :local afterMajor [:pick $numericVersion ($firstDot + 1) [:len $numericVersion]]
    :local secondDot [:find $afterMajor "."]
    :local routerMajor [:tonum [:pick $numericVersion 0 $firstDot]]
    :local routerMinor [:tonum [:pick $afterMajor 0 $secondDot]]
    :local routerPatch [:tonum [:pick $afterMajor ($secondDot + 1) [:len $afterMajor]]]
    :if (($routerMajor != $supportedMajor) || ($routerMinor < 24) || (($routerMinor = 24) && ($routerPatch < 4))) do={
        :error ("routercfg unknown-default-Mobile rollback: requires RouterOS v7 stable/long-term " . $minimumRouterVersion . " or newer; installed=" . $routerVersion)
    }
    # ROUTEROS_COMPATIBILITY_POLICY_END

    :local oldComment "routercfg ISP affinity: ordinary unknown destination via Unicom"
    :local mobileFromUnicom "routercfg ISP affinity: ordinary unknown destination via Mobile; rollback=Unicom"
    :local mobileFromPcc "routercfg ISP affinity: ordinary unknown destination via Mobile; rollback=PCC"
    :local genComments {"PCC weighted 2-of-5: bucket 0 to Unicom";"PCC weighted 2-of-5: bucket 1 to Unicom";"PCC weighted 3-of-5: bucket 2 to Mobile";"PCC weighted 3-of-5: bucket 3 to Mobile";"PCC weighted 3-of-5: bucket 4 to Mobile"}
    :local expectedBuckets {"both-addresses:5/0";"both-addresses:5/1";"both-addresses:5/2";"both-addresses:5/3";"both-addresses:5/4"}
    :local expectedMarks {"conn_unicom";"conn_unicom";"conn_mobile";"conn_mobile";"conn_mobile"}

    :local gen0Comment [:pick $genComments 0]
    :local gen1Comment [:pick $genComments 1]
    :local gen2Comment [:pick $genComments 2]
    :local gen3Comment [:pick $genComments 3]
    :local gen4Comment [:pick $genComments 4]
    :foreach requiredComment in=$genComments do={
        :if ([/ip firewall mangle print count-only as-value where comment=$requiredComment] != 1) do={
            :error ("routercfg unknown-default-Mobile rollback: missing or duplicate PCC rule: " . $requiredComment)
        }
    }
    :local gen0 [/ip firewall mangle find where comment=$gen0Comment]
    :local gen1 [/ip firewall mangle find where comment=$gen1Comment]
    :local gen2 [/ip firewall mangle find where comment=$gen2Comment]
    :local gen3 [/ip firewall mangle find where comment=$gen3Comment]
    :local gen4 [/ip firewall mangle find where comment=$gen4Comment]
    :local bucketIds {$gen0;$gen1;$gen2;$gen3;$gen4}
    :local enabledBuckets 0
    :for bucketIndex from=0 to=4 do={
        :local ruleId [:pick $bucketIds $bucketIndex]
        :if (([:tostr [/ip firewall mangle get $ruleId chain]] != "prerouting") || \
            ([:tostr [/ip firewall mangle get $ruleId action]] != "mark-connection") || \
            ([:tostr [/ip firewall mangle get $ruleId in-interface]] != "LAN01") || \
            ([:tostr [/ip firewall mangle get $ruleId dst-address-type]] != "!local") || \
            ([:tostr [/ip firewall mangle get $ruleId connection-state]] != "new") || \
            ([:tostr [/ip firewall mangle get $ruleId connection-mark]] != "no-mark") || \
            ([:tostr [/ip firewall mangle get $ruleId per-connection-classifier]] != [:pick $expectedBuckets $bucketIndex]) || \
            ([:tostr [/ip firewall mangle get $ruleId new-connection-mark]] != [:pick $expectedMarks $bucketIndex])) do={
            :error ("routercfg unknown-default-Mobile rollback: PCC bucket " . $bucketIndex . " identity changed")
        }
        :if ([:tostr [/ip firewall mangle get $ruleId disabled]] = "false") do={
            :set enabledBuckets ($enabledBuckets + 1)
        }
    }

    :local taggedCount 0
    :set taggedCount ($taggedCount + [/ip firewall mangle print count-only as-value where comment=$mobileFromUnicom])
    :set taggedCount ($taggedCount + [/ip firewall mangle print count-only as-value where comment=$mobileFromPcc])
    :local oldCount [/ip firewall mangle print count-only as-value where comment=$oldComment]
    :if (($taggedCount + $oldCount) != 1) do={
        :error "routercfg unknown-default-Mobile rollback: fallback is missing, duplicated or has an unknown identity"
    }

    :local restoreMode ""
    :local fallback
    :if ([/ip firewall mangle print count-only as-value where comment=$mobileFromUnicom] = 1) do={
        :set restoreMode "Unicom"
        :set fallback [/ip firewall mangle find where comment=$mobileFromUnicom]
    }
    :if ([/ip firewall mangle print count-only as-value where comment=$mobileFromPcc] = 1) do={
        :set restoreMode "PCC"
        :set fallback [/ip firewall mangle find where comment=$mobileFromPcc]
    }
    :if ($oldCount = 1) do={
        :set fallback [/ip firewall mangle find where comment=$oldComment]
    }

    :if (([:tostr [/ip firewall mangle get $fallback chain]] != "prerouting") || \
        ([:tostr [/ip firewall mangle get $fallback action]] != "mark-connection") || \
        ([:tostr [/ip firewall mangle get $fallback in-interface]] != "LAN01") || \
        ([:tostr [/ip firewall mangle get $fallback src-address]] != "!192.168.99.4") || \
        ([:tostr [/ip firewall mangle get $fallback connection-state]] != "new") || \
        ([:tostr [/ip firewall mangle get $fallback connection-mark]] != "no-mark") || \
        ([:tostr [/ip firewall mangle get $fallback dst-address-type]] != "!local") || \
        ([:tostr [/ip firewall mangle get $fallback passthrough]] != "true")) do={
        :error "routercfg unknown-default-Mobile rollback: fallback matcher changed"
    }

    :local fallbackDisabled [:tostr [/ip firewall mangle get $fallback disabled]]
    :local fallbackMark [:tostr [/ip firewall mangle get $fallback new-connection-mark]]
    :if ($taggedCount = 0) do={
        :if (($fallbackMark != "conn_unicom") || \
            ((($fallbackDisabled = "false") && ($enabledBuckets != 0)) || \
             (($fallbackDisabled = "true") && ($enabledBuckets != 5))) || \
            (($fallbackDisabled != "false") && ($fallbackDisabled != "true"))) do={
            :error "routercfg unknown-default-Mobile rollback: untagged state is mixed; no change made"
        }
        :put "Unknown-destination policy is already in a valid pre-migration state."
    } else={
        :if (($fallbackDisabled != "false") || ($fallbackMark != "conn_mobile") || ($enabledBuckets != 0)) do={
            :error "routercfg unknown-default-Mobile rollback: managed Mobile state is inconsistent"
        }

        :if ($restoreMode = "Unicom") do={
            /ip firewall mangle set $fallback new-connection-mark=conn_unicom comment=$oldComment
        }
        :if ($restoreMode = "PCC") do={
            # The earlier fallback stays active while all buckets are enabled.
            # Disabling it last avoids a temporary unclassified gap.
            :foreach ruleId in=$bucketIds do={ /ip firewall mangle enable $ruleId }
            /ip firewall mangle disable $fallback
            /ip firewall mangle set $fallback new-connection-mark=conn_unicom comment=$oldComment
        }

        :local expectedFallbackDisabled "false"
        :local expectedBucketDisabled "true"
        :if ($restoreMode = "PCC") do={
            :set expectedFallbackDisabled "true"
            :set expectedBucketDisabled "false"
        }
        :if (([:tostr [/ip firewall mangle get $fallback new-connection-mark]] != "conn_unicom") || \
            ([:tostr [/ip firewall mangle get $fallback comment]] != $oldComment) || \
            ([:tostr [/ip firewall mangle get $fallback disabled]] != $expectedFallbackDisabled)) do={
            :error "routercfg unknown-default-Mobile rollback: fallback post-check failed; discard Safe Mode"
        }
        :foreach ruleId in=$bucketIds do={
            :if ([:tostr [/ip firewall mangle get $ruleId disabled]] != $expectedBucketDisabled) do={
                :error "routercfg unknown-default-Mobile rollback: PCC post-check failed; discard Safe Mode"
            }
        }
        :log warning ("routercfg unknown-default-Mobile rollback complete; restored=" . $restoreMode)
        :put ("Unknown-destination policy restored to prior mode: " . $restoreMode)
    }
    } do={
        :local failureText [:tostr $caughtError]
        :log error ("routercfg unknown-default-Mobile rollback FAILED: " . $failureText)
        :put ("routercfg unknown-default-Mobile rollback FAILED: " . $failureText)
        :error $failureText
    }
}
