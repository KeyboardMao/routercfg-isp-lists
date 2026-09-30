# Make ordinary unknown/overlap IPv4 destinations prefer Mobile.
# Supports either known starting layout:
#   1) unknown fallback enabled via Unicom, general PCC disabled; or
#   2) unknown fallback disabled, all five general PCC buckets enabled.
# VPS A/B, PT, DNS pins and ISP-only destination rules must precede this rule.

{
    :onerror caughtError in={
    :log warning "routercfg unknown-default-Mobile migration: start"

    # ROUTEROS_COMPATIBILITY_POLICY_BEGIN
    :local routerVersion [:tostr [/system resource get version]]
    :local minimumRouterVersion "7.24.4"
    :local supportedMajor 7
    :local channelStart [:find $routerVersion " "]
    :if ([:typeof $channelStart] = "nil") do={
        :error ("routercfg unknown-default-Mobile: malformed RouterOS version: " . $routerVersion)
    }
    :local numericVersion [:pick $routerVersion 0 $channelStart]
    :local versionChannel [:pick $routerVersion ($channelStart + 1) [:len $routerVersion]]
    :if (($numericVersion ~ "^[0-9]+\\.[0-9]+\\.[0-9]+$") = false) do={
        :error ("routercfg unknown-default-Mobile: malformed RouterOS version: " . $routerVersion)
    }
    :if (($versionChannel != "(stable)") && ($versionChannel != "(long-term)")) do={
        :error ("routercfg unknown-default-Mobile: unsupported RouterOS channel: " . $versionChannel)
    }
    :local firstDot [:find $numericVersion "."]
    :local afterMajor [:pick $numericVersion ($firstDot + 1) [:len $numericVersion]]
    :local secondDot [:find $afterMajor "."]
    :local routerMajor [:tonum [:pick $numericVersion 0 $firstDot]]
    :local routerMinor [:tonum [:pick $afterMajor 0 $secondDot]]
    :local routerPatch [:tonum [:pick $afterMajor ($secondDot + 1) [:len $afterMajor]]]
    :if (($routerMajor != $supportedMajor) || ($routerMinor < 24) || (($routerMinor = 24) && ($routerPatch < 4))) do={
        :error ("routercfg unknown-default-Mobile: requires RouterOS v7 stable/long-term " . $minimumRouterVersion . " or newer; installed=" . $routerVersion)
    }
    # ROUTEROS_COMPATIBILITY_POLICY_END

    :local oldComment "routercfg ISP affinity: ordinary unknown destination via Unicom"
    :local mobileFromUnicom "routercfg ISP affinity: ordinary unknown destination via Mobile; rollback=Unicom"
    :local mobileFromPcc "routercfg ISP affinity: ordinary unknown destination via Mobile; rollback=PCC"
    :local unicomComment "routercfg ISP affinity: ordinary Unicom-only destination"
    :local mobileComment "routercfg ISP affinity: ordinary Mobile-only destination"
    :local genComments {"PCC weighted 2-of-5: bucket 0 to Unicom";"PCC weighted 2-of-5: bucket 1 to Unicom";"PCC weighted 3-of-5: bucket 2 to Mobile";"PCC weighted 3-of-5: bucket 3 to Mobile";"PCC weighted 3-of-5: bucket 4 to Mobile"}
    :local ptComments {"PCC PT 192.168.99.4 1-of-5: bucket 0 to Unicom";"PCC PT 192.168.99.4 4-of-5: bucket 1 to Mobile";"PCC PT 192.168.99.4 4-of-5: bucket 2 to Mobile";"PCC PT 192.168.99.4 4-of-5: bucket 3 to Mobile";"PCC PT 192.168.99.4 4-of-5: bucket 4 to Mobile"}
    :local vpsComments {"VPS pairing: classify 154.17.228.232";"VPS pairing: route 154.17.228.232";"VPS pairing: classify 45.143.131.150";"VPS pairing: route 45.143.131.150"}
    :local requiredComments {"PCC bypass: destinations owned by this router";"PCC bypass: RFC1918 LAN modem and VPN destinations";"Mark inbound connections from Unicom PPPoE";"Mark inbound connections from Mobile PPPoE";"Router-origin reply route for Unicom-marked connections";"Router-origin reply route for Mobile-marked connections";"PT tracker: 192.168.99.4 HTTP HTTPS via Unicom";"PT tracker: 192.168.99.4 QUIC HTTPS via Unicom";"routercfg DNS pin: OpenWrt Unicom DNS";"routercfg DNS pin: OpenWrt Mobile DNS";"Route marked Unicom connections via to_unicom";"Route marked Mobile connections via to_mobile"}

    :foreach requiredComment in=$requiredComments do={
        :if ([/ip firewall mangle print count-only as-value where comment=$requiredComment] != 1) do={
            :error ("routercfg unknown-default-Mobile: missing or duplicate rule: " . $requiredComment)
        }
    }
    :foreach requiredComment in={$unicomComment;$mobileComment} do={
        :if ([/ip firewall mangle print count-only as-value where comment=$requiredComment] != 1) do={
            :error ("routercfg unknown-default-Mobile: missing or duplicate ISP rule: " . $requiredComment)
        }
    }
    :foreach requiredComment in=$genComments do={
        :if ([/ip firewall mangle print count-only as-value where comment=$requiredComment] != 1) do={
            :error ("routercfg unknown-default-Mobile: missing or duplicate PCC rule: " . $requiredComment)
        }
    }
    :foreach requiredComment in=$vpsComments do={
        :if ([/ip firewall mangle print count-only as-value where comment=$requiredComment] != 1) do={
            :error ("routercfg unknown-default-Mobile: missing or duplicate VPS rule: " . $requiredComment)
        }
    }
    :foreach requiredComment in=$ptComments do={
        :if ([/ip firewall mangle print count-only as-value where comment=$requiredComment] != 1) do={
            :error ("routercfg unknown-default-Mobile: missing or duplicate PT rule: " . $requiredComment)
        }
    }

    # Prove that local, private, VPN and modem traffic still exits policy
    # processing before any Internet connection mark is assigned.
    :local bypassLocal [/ip firewall mangle find where comment="PCC bypass: destinations owned by this router"]
    :local bypassPrivate [/ip firewall mangle find where comment="PCC bypass: RFC1918 LAN modem and VPN destinations"]
    :if (([:tostr [/ip firewall mangle get $bypassLocal chain]] != "prerouting") || \
        ([:tostr [/ip firewall mangle get $bypassLocal action]] != "accept") || \
        ([:tostr [/ip firewall mangle get $bypassLocal in-interface]] != "LAN01") || \
        ([:tostr [/ip firewall mangle get $bypassLocal dst-address-type]] != "local") || \
        ([:tostr [/ip firewall mangle get $bypassLocal disabled]] != "false")) do={
        :error "routercfg unknown-default-Mobile: router-local bypass changed"
    }
    :if (([:tostr [/ip firewall mangle get $bypassPrivate chain]] != "prerouting") || \
        ([:tostr [/ip firewall mangle get $bypassPrivate action]] != "accept") || \
        ([:tostr [/ip firewall mangle get $bypassPrivate in-interface]] != "LAN01") || \
        ([:tostr [/ip firewall mangle get $bypassPrivate dst-address-list]] != "Lan_ip") || \
        ([:tostr [/ip firewall mangle get $bypassPrivate disabled]] != "false")) do={
        :error "routercfg unknown-default-Mobile: RFC1918 bypass changed"
    }
    :foreach privatePrefix in={"10.0.0.0/8";"172.16.0.0/12";"192.168.0.0/16"} do={
        :if ([/ip firewall address-list print count-only as-value where list="Lan_ip" and address=$privatePrefix] != 1) do={
            :error ("routercfg unknown-default-Mobile: Lan_ip lacks unique RFC1918 prefix " . $privatePrefix)
        }
    }

    # WAN ingress and router-origin reply rules are separate from the LAN-only
    # fallback. Validate their exact marks so public forwards and VPN replies keep
    # the ingress WAN symmetry.
    :local inboundU [/ip firewall mangle find where comment="Mark inbound connections from Unicom PPPoE"]
    :local inboundM [/ip firewall mangle find where comment="Mark inbound connections from Mobile PPPoE"]
    :if (([:tostr [/ip firewall mangle get $inboundU chain]] != "prerouting") || \
        ([:tostr [/ip firewall mangle get $inboundU action]] != "mark-connection") || \
        ([:tostr [/ip firewall mangle get $inboundU in-interface]] != "pppoe-chinaunicom") || \
        ([:tostr [/ip firewall mangle get $inboundU connection-mark]] != "no-mark") || \
        ([:tostr [/ip firewall mangle get $inboundU new-connection-mark]] != "conn_unicom") || \
        ([:tostr [/ip firewall mangle get $inboundU disabled]] != "false")) do={
        :error "routercfg unknown-default-Mobile: Unicom ingress symmetry changed"
    }
    :if (([:tostr [/ip firewall mangle get $inboundM chain]] != "prerouting") || \
        ([:tostr [/ip firewall mangle get $inboundM action]] != "mark-connection") || \
        ([:tostr [/ip firewall mangle get $inboundM in-interface]] != "pppoe-chinamobile") || \
        ([:tostr [/ip firewall mangle get $inboundM connection-mark]] != "no-mark") || \
        ([:tostr [/ip firewall mangle get $inboundM new-connection-mark]] != "conn_mobile") || \
        ([:tostr [/ip firewall mangle get $inboundM disabled]] != "false")) do={
        :error "routercfg unknown-default-Mobile: Mobile ingress symmetry changed"
    }

    :local fallbackCount 0
    :set fallbackCount ($fallbackCount + [/ip firewall mangle print count-only as-value where comment=$oldComment])
    :set fallbackCount ($fallbackCount + [/ip firewall mangle print count-only as-value where comment=$mobileFromUnicom])
    :set fallbackCount ($fallbackCount + [/ip firewall mangle print count-only as-value where comment=$mobileFromPcc])
    :if ($fallbackCount != 1) do={
        :error "routercfg unknown-default-Mobile: fallback rule is missing, duplicated or has an unknown identity"
    }

    :local fallback
    :local previousMode ""
    :if ([/ip firewall mangle print count-only as-value where comment=$oldComment] = 1) do={
        :set fallback [/ip firewall mangle find where comment=$oldComment]
    }
    :if ([/ip firewall mangle print count-only as-value where comment=$mobileFromUnicom] = 1) do={
        :set fallback [/ip firewall mangle find where comment=$mobileFromUnicom]
        :set previousMode "already-Unicom"
    }
    :if ([/ip firewall mangle print count-only as-value where comment=$mobileFromPcc] = 1) do={
        :set fallback [/ip firewall mangle find where comment=$mobileFromPcc]
        :set previousMode "already-PCC"
    }

    :if (([:tostr [/ip firewall mangle get $fallback chain]] != "prerouting") || \
        ([:tostr [/ip firewall mangle get $fallback action]] != "mark-connection") || \
        ([:tostr [/ip firewall mangle get $fallback in-interface]] != "LAN01") || \
        ([:tostr [/ip firewall mangle get $fallback src-address]] != "!192.168.99.4") || \
        ([:tostr [/ip firewall mangle get $fallback connection-state]] != "new") || \
        ([:tostr [/ip firewall mangle get $fallback connection-mark]] != "no-mark") || \
        ([:tostr [/ip firewall mangle get $fallback dst-address-type]] != "!local") || \
        ([:tostr [/ip firewall mangle get $fallback passthrough]] != "true")) do={
        :error "routercfg unknown-default-Mobile: fallback matcher differs from the approved layout"
    }

    :local gen0Comment [:pick $genComments 0]
    :local gen1Comment [:pick $genComments 1]
    :local gen2Comment [:pick $genComments 2]
    :local gen3Comment [:pick $genComments 3]
    :local gen4Comment [:pick $genComments 4]
    :local gen0 [/ip firewall mangle find where comment=$gen0Comment]
    :local gen1 [/ip firewall mangle find where comment=$gen1Comment]
    :local gen2 [/ip firewall mangle find where comment=$gen2Comment]
    :local gen3 [/ip firewall mangle find where comment=$gen3Comment]
    :local gen4 [/ip firewall mangle find where comment=$gen4Comment]
    :local bucketIds {$gen0;$gen1;$gen2;$gen3;$gen4}
    :local expectedBuckets {"both-addresses:5/0";"both-addresses:5/1";"both-addresses:5/2";"both-addresses:5/3";"both-addresses:5/4"}
    :local expectedMarks {"conn_unicom";"conn_unicom";"conn_mobile";"conn_mobile";"conn_mobile"}
    :local enabledBuckets 0
    :for bucketIndex from=0 to=4 do={
        :local ruleId [:pick $bucketIds $bucketIndex]
        :if (([:tostr [/ip firewall mangle get $ruleId chain]] != "prerouting") || \
            ([:tostr [/ip firewall mangle get $ruleId action]] != "mark-connection") || \
            ([:tostr [/ip firewall mangle get $ruleId in-interface]] != "LAN01") || \
            ([:tostr [/ip firewall mangle get $ruleId dst-address-type]] != "!local") || \
            ([:tostr [/ip firewall mangle get $ruleId connection-mark]] != "no-mark") || \
            ([:tostr [/ip firewall mangle get $ruleId connection-state]] != "new") || \
            ([:tostr [/ip firewall mangle get $ruleId per-connection-classifier]] != [:pick $expectedBuckets $bucketIndex]) || \
            ([:tostr [/ip firewall mangle get $ruleId new-connection-mark]] != [:pick $expectedMarks $bucketIndex])) do={
            :error ("routercfg unknown-default-Mobile: PCC bucket " . $bucketIndex . " identity changed")
        }
        :if ([:tostr [/ip firewall mangle get $ruleId disabled]] = "false") do={
            :set enabledBuckets ($enabledBuckets + 1)
        }
    }

    # Validate every dedicated PT bucket. The unknown fallback explicitly excludes
    # 192.168.99.4, so the existing 1/5 Unicom + 4/5 Mobile policy remains terminal.
    :local expectedPtMarks {"conn_unicom";"conn_mobile";"conn_mobile";"conn_mobile";"conn_mobile"}
    :for bucketIndex from=0 to=4 do={
        :local ptComment [:pick $ptComments $bucketIndex]
        :local ptId [/ip firewall mangle find where comment=$ptComment]
        :if (([:tostr [/ip firewall mangle get $ptId chain]] != "prerouting") || \
            ([:tostr [/ip firewall mangle get $ptId action]] != "mark-connection") || \
            ([:tostr [/ip firewall mangle get $ptId in-interface]] != "LAN01") || \
            ([:tostr [/ip firewall mangle get $ptId src-address]] != "192.168.99.4") || \
            ([:tostr [/ip firewall mangle get $ptId dst-address-type]] != "!local") || \
            ([:tostr [/ip firewall mangle get $ptId connection-state]] != "new") || \
            ([:tostr [/ip firewall mangle get $ptId connection-mark]] != "no-mark") || \
            ([:tostr [/ip firewall mangle get $ptId per-connection-classifier]] != ("both-addresses-and-ports:5/" . $bucketIndex)) || \
            ([:tostr [/ip firewall mangle get $ptId new-connection-mark]] != [:pick $expectedPtMarks $bucketIndex]) || \
            ([:tostr [/ip firewall mangle get $ptId disabled]] != "false")) do={
            :error ("routercfg unknown-default-Mobile: PT bucket " . $bucketIndex . " identity changed")
        }
    }

    :local trackerTcp [/ip firewall mangle find where comment="PT tracker: 192.168.99.4 HTTP HTTPS via Unicom"]
    :local trackerQuic [/ip firewall mangle find where comment="PT tracker: 192.168.99.4 QUIC HTTPS via Unicom"]
    :local trackerTcpPorts [:tostr [/ip firewall mangle get $trackerTcp dst-port]]
    :if (([:tostr [/ip firewall mangle get $trackerTcp chain]] != "prerouting") || \
        ([:tostr [/ip firewall mangle get $trackerTcp action]] != "mark-connection") || \
        ([:tostr [/ip firewall mangle get $trackerTcp in-interface]] != "LAN01") || \
        ([:tostr [/ip firewall mangle get $trackerTcp src-address]] != "192.168.99.4") || \
        ([:tostr [/ip firewall mangle get $trackerTcp protocol]] != "tcp") || \
        (($trackerTcpPorts != "80,443") && ($trackerTcpPorts != "443,80")) || \
        ([:tostr [/ip firewall mangle get $trackerTcp connection-state]] != "new") || \
        ([:tostr [/ip firewall mangle get $trackerTcp connection-mark]] != "no-mark") || \
        ([:tostr [/ip firewall mangle get $trackerTcp new-connection-mark]] != "conn_unicom") || \
        ([:tostr [/ip firewall mangle get $trackerTcp disabled]] != "false")) do={
        :error "routercfg unknown-default-Mobile: PT TCP tracker rule changed"
    }
    :if (([:tostr [/ip firewall mangle get $trackerQuic chain]] != "prerouting") || \
        ([:tostr [/ip firewall mangle get $trackerQuic action]] != "mark-connection") || \
        ([:tostr [/ip firewall mangle get $trackerQuic in-interface]] != "LAN01") || \
        ([:tostr [/ip firewall mangle get $trackerQuic src-address]] != "192.168.99.4") || \
        ([:tostr [/ip firewall mangle get $trackerQuic protocol]] != "udp") || \
        ([:tostr [/ip firewall mangle get $trackerQuic dst-port]] != "443") || \
        ([:tostr [/ip firewall mangle get $trackerQuic connection-state]] != "new") || \
        ([:tostr [/ip firewall mangle get $trackerQuic connection-mark]] != "no-mark") || \
        ([:tostr [/ip firewall mangle get $trackerQuic new-connection-mark]] != "conn_unicom") || \
        ([:tostr [/ip firewall mangle get $trackerQuic disabled]] != "false")) do={
        :error "routercfg unknown-default-Mobile: PT QUIC tracker rule changed"
    }

    # OpenWrt's two explicit DNS targets keep their original WANs. Other traffic
    # from 192.168.99.252 follows the ordinary destination policy.
    :local dnsU [/ip firewall mangle find where comment="routercfg DNS pin: OpenWrt Unicom DNS"]
    :local dnsM [/ip firewall mangle find where comment="routercfg DNS pin: OpenWrt Mobile DNS"]
    :if (([:tostr [/ip firewall mangle get $dnsU chain]] != "prerouting") || \
        ([:tostr [/ip firewall mangle get $dnsU action]] != "mark-connection") || \
        ([:tostr [/ip firewall mangle get $dnsU in-interface]] != "LAN01") || \
        ([:tostr [/ip firewall mangle get $dnsU src-address]] != "192.168.99.252") || \
        ([:tostr [/ip firewall mangle get $dnsU dst-address]] != "202.99.96.68") || \
        ([:tostr [/ip firewall mangle get $dnsU connection-state]] != "new") || \
        ([:tostr [/ip firewall mangle get $dnsU connection-mark]] != "no-mark") || \
        ([:tostr [/ip firewall mangle get $dnsU new-connection-mark]] != "conn_unicom") || \
        ([:tostr [/ip firewall mangle get $dnsU passthrough]] != "true") || \
        ([:tostr [/ip firewall mangle get $dnsU disabled]] != "false")) do={
        :error "routercfg unknown-default-Mobile: OpenWrt Unicom DNS pin changed"
    }
    :if (([:tostr [/ip firewall mangle get $dnsM chain]] != "prerouting") || \
        ([:tostr [/ip firewall mangle get $dnsM action]] != "mark-connection") || \
        ([:tostr [/ip firewall mangle get $dnsM in-interface]] != "LAN01") || \
        ([:tostr [/ip firewall mangle get $dnsM src-address]] != "192.168.99.252") || \
        ([:tostr [/ip firewall mangle get $dnsM dst-address]] != "211.137.160.5") || \
        ([:tostr [/ip firewall mangle get $dnsM connection-state]] != "new") || \
        ([:tostr [/ip firewall mangle get $dnsM connection-mark]] != "no-mark") || \
        ([:tostr [/ip firewall mangle get $dnsM new-connection-mark]] != "conn_mobile") || \
        ([:tostr [/ip firewall mangle get $dnsM passthrough]] != "true") || \
        ([:tostr [/ip firewall mangle get $dnsM disabled]] != "false")) do={
        :error "routercfg unknown-default-Mobile: OpenWrt Mobile DNS pin changed"
    }

    # The updater may rotate these address-list names between managed A/B slots.
    # Validate the classifiers and require different non-empty lists without tying
    # the migration to one slot.
    :local ispU [/ip firewall mangle find where comment=$unicomComment]
    :local ispM [/ip firewall mangle find where comment=$mobileComment]
    :local ispUList [:tostr [/ip firewall mangle get $ispU dst-address-list]]
    :local ispMList [:tostr [/ip firewall mangle get $ispM dst-address-list]]
    :if (([:tostr [/ip firewall mangle get $ispU chain]] != "prerouting") || \
        ([:tostr [/ip firewall mangle get $ispU action]] != "mark-connection") || \
        ([:tostr [/ip firewall mangle get $ispU in-interface]] != "LAN01") || \
        ([:tostr [/ip firewall mangle get $ispU src-address]] != "!192.168.99.4") || \
        ([:tostr [/ip firewall mangle get $ispU connection-state]] != "new") || \
        ([:tostr [/ip firewall mangle get $ispU connection-mark]] != "no-mark") || \
        ([:tostr [/ip firewall mangle get $ispU new-connection-mark]] != "conn_unicom") || \
        ([:tostr [/ip firewall mangle get $ispU disabled]] != "false") || ($ispUList = "")) do={
        :error "routercfg unknown-default-Mobile: Unicom-only classifier changed"
    }
    :if (([:tostr [/ip firewall mangle get $ispM chain]] != "prerouting") || \
        ([:tostr [/ip firewall mangle get $ispM action]] != "mark-connection") || \
        ([:tostr [/ip firewall mangle get $ispM in-interface]] != "LAN01") || \
        ([:tostr [/ip firewall mangle get $ispM src-address]] != "!192.168.99.4") || \
        ([:tostr [/ip firewall mangle get $ispM connection-state]] != "new") || \
        ([:tostr [/ip firewall mangle get $ispM connection-mark]] != "no-mark") || \
        ([:tostr [/ip firewall mangle get $ispM new-connection-mark]] != "conn_mobile") || \
        ([:tostr [/ip firewall mangle get $ispM disabled]] != "false") || ($ispMList = "") || ($ispMList = $ispUList)) do={
        :error "routercfg unknown-default-Mobile: Mobile-only classifier changed"
    }

    :local routeU [/ip firewall mangle find where comment="Route marked Unicom connections via to_unicom"]
    :local routeM [/ip firewall mangle find where comment="Route marked Mobile connections via to_mobile"]
    :if (([:tostr [/ip firewall mangle get $routeU chain]] != "prerouting") || \
        ([:tostr [/ip firewall mangle get $routeU action]] != "mark-routing") || \
        ([:tostr [/ip firewall mangle get $routeU in-interface]] != "LAN01") || \
        ([:tostr [/ip firewall mangle get $routeU connection-mark]] != "conn_unicom") || \
        ([:tostr [/ip firewall mangle get $routeU new-routing-mark]] != "to_unicom") || \
        ([:tostr [/ip firewall mangle get $routeU passthrough]] != "false") || \
        ([:tostr [/ip firewall mangle get $routeU disabled]] != "false")) do={
        :error "routercfg unknown-default-Mobile: Unicom marked-routing rule changed"
    }
    :if (([:tostr [/ip firewall mangle get $routeM chain]] != "prerouting") || \
        ([:tostr [/ip firewall mangle get $routeM action]] != "mark-routing") || \
        ([:tostr [/ip firewall mangle get $routeM in-interface]] != "LAN01") || \
        ([:tostr [/ip firewall mangle get $routeM connection-mark]] != "conn_mobile") || \
        ([:tostr [/ip firewall mangle get $routeM new-routing-mark]] != "to_mobile") || \
        ([:tostr [/ip firewall mangle get $routeM passthrough]] != "false") || \
        ([:tostr [/ip firewall mangle get $routeM disabled]] != "false")) do={
        :error "routercfg unknown-default-Mobile: Mobile marked-routing rule changed"
    }

    :local v154cComment [:pick $vpsComments 0]
    :local v154rComment [:pick $vpsComments 1]
    :local v45cComment [:pick $vpsComments 2]
    :local v45rComment [:pick $vpsComments 3]
    :local v154c [/ip firewall mangle find where comment=$v154cComment]
    :local v154r [/ip firewall mangle find where comment=$v154rComment]
    :local v45c [/ip firewall mangle find where comment=$v45cComment]
    :local v45r [/ip firewall mangle find where comment=$v45rComment]
    :local v154mark [:tostr [/ip firewall mangle get $v154c new-connection-mark]]
    :local v45mark [:tostr [/ip firewall mangle get $v45c new-connection-mark]]
    :if (($v154mark != "conn_unicom") && ($v154mark != "conn_mobile")) do={ :error "routercfg unknown-default-Mobile: VPS 154 connection mark is invalid" }
    :if (($v45mark != "conn_unicom") && ($v45mark != "conn_mobile")) do={ :error "routercfg unknown-default-Mobile: VPS 45 connection mark is invalid" }
    :if (([:tostr [/ip firewall mangle get $v154c chain]] != "prerouting") || \
        ([:tostr [/ip firewall mangle get $v154c action]] != "mark-connection") || \
        ([:tostr [/ip firewall mangle get $v154c in-interface]] != "LAN01") || \
        ([:tostr [/ip firewall mangle get $v154c dst-address]] != "154.17.228.232") || \
        ([:tostr [/ip firewall mangle get $v154c connection-mark]] != "no-mark") || \
        ([:tostr [/ip firewall mangle get $v154c disabled]] != "false") || \
        ([:tostr [/ip firewall mangle get $v45c chain]] != "prerouting") || \
        ([:tostr [/ip firewall mangle get $v45c action]] != "mark-connection") || \
        ([:tostr [/ip firewall mangle get $v45c in-interface]] != "LAN01") || \
        ([:tostr [/ip firewall mangle get $v45c dst-address]] != "45.143.131.150") || \
        ([:tostr [/ip firewall mangle get $v45c connection-mark]] != "no-mark") || \
        ([:tostr [/ip firewall mangle get $v45c disabled]] != "false")) do={
        :error "routercfg unknown-default-Mobile: VPS classifiers changed"
    }
    :if (([:tostr [/ip firewall mangle get $v154r connection-mark]] != $v154mark) || \
        ([:tostr [/ip firewall mangle get $v45r connection-mark]] != $v45mark) || \
        ([:tostr [/ip firewall mangle get $v154r action]] != "mark-routing") || \
        ([:tostr [/ip firewall mangle get $v45r action]] != "mark-routing") || \
        ([:tostr [/ip firewall mangle get $v154r dst-address]] != "154.17.228.232") || \
        ([:tostr [/ip firewall mangle get $v45r dst-address]] != "45.143.131.150") || \
        ([:tostr [/ip firewall mangle get $v154r disabled]] != "false") || \
        ([:tostr [/ip firewall mangle get $v45r disabled]] != "false")) do={
        :error "routercfg unknown-default-Mobile: VPS connection and route marks disagree"
    }
    :if ((($v154mark = "conn_unicom") && ([:tostr [/ip firewall mangle get $v154r new-routing-mark]] != "to_unicom")) || \
        (($v154mark = "conn_mobile") && ([:tostr [/ip firewall mangle get $v154r new-routing-mark]] != "to_mobile")) || \
        (($v45mark = "conn_unicom") && ([:tostr [/ip firewall mangle get $v45r new-routing-mark]] != "to_unicom")) || \
        (($v45mark = "conn_mobile") && ([:tostr [/ip firewall mangle get $v45r new-routing-mark]] != "to_mobile"))) do={
        :error "routercfg unknown-default-Mobile: VPS routing marks do not match their selected WANs"
    }

    # The VPS switch also controls two main-table /32 routes. Their gateways must
    # agree with the selected marks or unmarked router-origin traffic could diverge.
    :local h154 ""
    :local h45 ""
    :local h154n 0
    :local h45n 0
    :foreach routeId in=[/ip route find] do={
        :local routeDestination [:tostr [/ip route get $routeId dst-address]]
        :local routeTable [:tostr [/ip route get $routeId routing-table]]
        :if (($routeDestination = "154.17.228.232/32") && ($routeTable = "main")) do={ :set h154 $routeId; :set h154n ($h154n + 1) }
        :if (($routeDestination = "45.143.131.150/32") && ($routeTable = "main")) do={ :set h45 $routeId; :set h45n ($h45n + 1) }
    }
    :if (($h154n != 1) || ($h45n != 1)) do={ :error "routercfg unknown-default-Mobile: VPS main /32 routes changed" }
    :local expected154Gateway "pppoe-chinaunicom"
    :local expected45Gateway "pppoe-chinaunicom"
    :if ($v154mark = "conn_mobile") do={ :set expected154Gateway "pppoe-chinamobile" }
    :if ($v45mark = "conn_mobile") do={ :set expected45Gateway "pppoe-chinamobile" }
    :if (([:tostr [/ip route get $h154 gateway]] != $expected154Gateway) || \
        ([:tostr [/ip route get $h45 gateway]] != $expected45Gateway)) do={
        :error "routercfg unknown-default-Mobile: VPS main routes disagree with VPS marks"
    }

    # Prove that both policy tables retain a primary default, the cross-WAN
    # interface-state backup, and a lookup rule that permits main-table fallback.
    :if ([/routing table print count-only as-value where name="to_unicom"] != 1) do={
        :error "routercfg unknown-default-Mobile: to_unicom table changed"
    }
    :if ([/routing table print count-only as-value where name="to_mobile"] != 1) do={
        :error "routercfg unknown-default-Mobile: to_mobile table changed"
    }
    :local tableU [/routing table find where name="to_unicom"]
    :local tableM [/routing table find where name="to_mobile"]
    :if (([:tostr [/routing table get $tableU fib]] != "true") || ([:tostr [/routing table get $tableM fib]] != "true")) do={
        :error "routercfg unknown-default-Mobile: policy tables are not FIB tables"
    }
    :if ([/routing rule print count-only as-value where routing-mark="to_unicom" and action=lookup and table="to_unicom"] != 1) do={
        :error "routercfg unknown-default-Mobile: to_unicom routing rule changed"
    }
    :if ([/routing rule print count-only as-value where routing-mark="to_mobile" and action=lookup and table="to_mobile"] != 1) do={
        :error "routercfg unknown-default-Mobile: to_mobile routing rule changed"
    }
    :if ([/routing rule print count-only as-value where routing-mark="to_unicom" and min-prefix=0] != 0) do={
        :error "routercfg unknown-default-Mobile: to_unicom still suppresses default lookup"
    }
    :if ([/routing rule print count-only as-value where routing-mark="to_mobile" and min-prefix=0] != 0) do={
        :error "routercfg unknown-default-Mobile: to_mobile still suppresses default lookup"
    }
    :if ([/ip route print count-only as-value where routing-table="to_unicom" and dst-address="0.0.0.0/0" and gateway="pppoe-chinaunicom" and distance=50] != 1) do={
        :error "routercfg unknown-default-Mobile: Unicom primary policy default changed"
    }
    :if ([/ip route print count-only as-value where comment="routercfg failover: Mobile backup for Unicom policy table" and routing-table="to_unicom" and dst-address="0.0.0.0/0" and gateway="pppoe-chinamobile" and distance=150] != 1) do={
        :error "routercfg unknown-default-Mobile: Unicom-table Mobile backup changed"
    }
    :if ([/ip route print count-only as-value where routing-table="to_mobile" and dst-address="0.0.0.0/0" and gateway="pppoe-chinamobile" and distance=51] != 1) do={
        :error "routercfg unknown-default-Mobile: Mobile primary policy default changed"
    }
    :if ([/ip route print count-only as-value where comment="routercfg failover: Unicom backup for Mobile policy table" and routing-table="to_mobile" and dst-address="0.0.0.0/0" and gateway="pppoe-chinaunicom" and distance=151] != 1) do={
        :error "routercfg unknown-default-Mobile: Mobile-table Unicom backup changed"
    }

    :local replyU [/ip firewall mangle find where comment="Router-origin reply route for Unicom-marked connections"]
    :local replyM [/ip firewall mangle find where comment="Router-origin reply route for Mobile-marked connections"]
    :if (([:tostr [/ip firewall mangle get $replyU chain]] != "output") || \
        ([:tostr [/ip firewall mangle get $replyU action]] != "mark-routing") || \
        ([:tostr [/ip firewall mangle get $replyU connection-mark]] != "conn_unicom") || \
        ([:tostr [/ip firewall mangle get $replyU new-routing-mark]] != "to_unicom") || \
        ([:tostr [/ip firewall mangle get $replyU disabled]] != "false")) do={
        :error "routercfg unknown-default-Mobile: Unicom router-reply symmetry changed"
    }
    :if (([:tostr [/ip firewall mangle get $replyM chain]] != "output") || \
        ([:tostr [/ip firewall mangle get $replyM action]] != "mark-routing") || \
        ([:tostr [/ip firewall mangle get $replyM connection-mark]] != "conn_mobile") || \
        ([:tostr [/ip firewall mangle get $replyM new-routing-mark]] != "to_mobile") || \
        ([:tostr [/ip firewall mangle get $replyM disabled]] != "false")) do={
        :error "routercfg unknown-default-Mobile: Mobile router-reply symmetry changed"
    }

    # Cross-WAN failover is usable only when each physical egress has exactly one
    # enabled general masquerade rule.
    :local natU 0
    :local natM 0
    :foreach natId in=[/ip firewall nat find] do={
        :local natChain [:tostr [/ip firewall nat get $natId chain]]
        :local natAction [:tostr [/ip firewall nat get $natId action]]
        :local natOutput [:tostr [/ip firewall nat get $natId out-interface]]
        :local natSource [:tostr [/ip firewall nat get $natId src-address]]
        :local natDisabled [:tostr [/ip firewall nat get $natId disabled]]
        :if (($natChain = "srcnat") && ($natAction = "masquerade") && ($natOutput = "pppoe-chinaunicom") && ($natSource = "") && ($natDisabled = "false")) do={ :set natU ($natU + 1) }
        :if (($natChain = "srcnat") && ($natAction = "masquerade") && ($natOutput = "pppoe-chinamobile") && ($natSource = "") && ($natDisabled = "false")) do={ :set natM ($natM + 1) }
    }
    :if (($natU != 1) || ($natM != 1)) do={
        :error "routercfg unknown-default-Mobile: expected one enabled general masquerade per PPPoE WAN"
    }

    # These objects are not edited. Their counts prove that public Unicom NAT,
    # hairpin NAT, VPN forwarding and QoS have not drifted into an interacting state.
    :if ([/ip firewall nat print count-only as-value where comment~"^routercfg phase6: public Unicom"] != 9) do={
        :error "routercfg unknown-default-Mobile: public Unicom NAT set changed"
    }
    :if ([/ip firewall nat print count-only as-value where comment~"^routercfg phase6 hairpin dstnat:"] != 8) do={
        :error "routercfg unknown-default-Mobile: hairpin destination NAT set changed"
    }
    :if ([/ip firewall nat print count-only as-value where comment="routercfg phase6 hairpin srcnat: LAN clients to LAN servers"] != 1) do={
        :error "routercfg unknown-default-Mobile: hairpin source NAT changed"
    }
    :if ([/ip firewall filter print count-only as-value where comment="routercfg phase6: allow IKEv2 clients to internet"] != 1) do={
        :error "routercfg unknown-default-Mobile: IKEv2 forward allowance changed"
    }
    :if ([/ip firewall filter print count-only as-value where comment="routercfg phase6: drop unsolicited new WAN forwarding"] != 1) do={
        :error "routercfg unknown-default-Mobile: WAN forward boundary changed"
    }
    :if ([/ip firewall mangle print count-only as-value where comment~"^qos-(upload|download):"] != 28) do={
        :error "routercfg unknown-default-Mobile: QoS classifier set changed"
    }
    :if ([/ip firewall address-list print count-only as-value where list="qos_priority_vps" and address="154.17.228.232"] != 1) do={
        :error "routercfg unknown-default-Mobile: VPS 154 QoS priority entry changed"
    }
    :if ([/ip firewall address-list print count-only as-value where list="qos_priority_vps" and address="45.143.131.150"] != 1) do={
        :error "routercfg unknown-default-Mobile: VPS 45 QoS priority entry changed"
    }
    :if ([/ip firewall filter print count-only as-value where disabled=no and action=fasttrack-connection] != 0) do={
        :error "routercfg unknown-default-Mobile: active FastTrack would bypass policy/QoS"
    }

    # Treat the complete prerouting policy-routing surface as a closed set.
    # Relative-order checks alone would not detect an unreviewed rule inserted
    # between known anchors or a historical rule without in-interface=LAN01.
    # Exactly 27 rules belong to this approved layout: 21 connection classifiers
    # (19 LAN plus two PPPoE inbound), four routing-mark consumers and two bypasses.
    :local preroutingRuleCount 0
    :local preroutingClassifierCount 0
    :local preroutingRoutingCount 0
    :local preroutingBypassCount 0
    :foreach mangleObjectId in=[/ip firewall mangle find] do={
        :local mangleChainValue [:tostr [/ip firewall mangle get $mangleObjectId chain]]
        :local mangleActionValue [:tostr [/ip firewall mangle get $mangleObjectId action]]
        :if ($mangleChainValue = "prerouting") do={
            :set preroutingRuleCount ($preroutingRuleCount + 1)
            :local mangleCommentValue [:tostr [/ip firewall mangle get $mangleObjectId comment]]
            :local approvedRule false
            :foreach approvedComment in=$requiredComments do={
                :if ($mangleCommentValue = $approvedComment) do={ :set approvedRule true }
            }
            :foreach approvedComment in=$genComments do={
                :if ($mangleCommentValue = $approvedComment) do={ :set approvedRule true }
            }
            :foreach approvedComment in=$ptComments do={
                :if ($mangleCommentValue = $approvedComment) do={ :set approvedRule true }
            }
            :foreach approvedComment in=$vpsComments do={
                :if ($mangleCommentValue = $approvedComment) do={ :set approvedRule true }
            }
            :if (($mangleCommentValue = $unicomComment) || ($mangleCommentValue = $mobileComment) || \
                ($mangleCommentValue = $oldComment) || ($mangleCommentValue = $mobileFromUnicom) || \
                ($mangleCommentValue = $mobileFromPcc)) do={ :set approvedRule true }
            :if ($approvedRule = false) do={
                :error ("routercfg unknown-default-Mobile: unreviewed prerouting policy rule: " . $mangleObjectId . " comment=" . $mangleCommentValue)
            }
            :if ($mangleActionValue = "mark-connection") do={ :set preroutingClassifierCount ($preroutingClassifierCount + 1) }
            :if ($mangleActionValue = "mark-routing") do={ :set preroutingRoutingCount ($preroutingRoutingCount + 1) }
            :if ($mangleActionValue = "accept") do={ :set preroutingBypassCount ($preroutingBypassCount + 1) }
        }
    }
    :if (($preroutingRuleCount != 27) || ($preroutingClassifierCount != 21) || \
        ($preroutingRoutingCount != 4) || ($preroutingBypassCount != 2)) do={
        :error ("routercfg unknown-default-Mobile: prerouting policy rule counts changed; total=" . $preroutingRuleCount . " classifiers=" . $preroutingClassifierCount . " routing=" . $preroutingRoutingCount . " bypasses=" . $preroutingBypassCount)
    }

    :local pt0Comment [:pick $ptComments 0]
    :local pt4Comment [:pick $ptComments 4]
    :local pt0 [/ip firewall mangle find where comment=$pt0Comment]
    :local pt4 [/ip firewall mangle find where comment=$pt4Comment]
    :local pInboundU -1; :local pInboundM -1; :local pBypassLocal -1; :local pBypassPrivate -1
    :local pV154c -1; :local pV154r -1; :local pV45c -1; :local pV45r -1
    :local pTrackerTcp -1; :local pTrackerQuic -1; :local pPt0 -1; :local pPt4 -1
    :local pDnsU -1; :local pDnsM -1; :local pU -1; :local pM -1; :local pFallback -1
    :local pG0 -1; :local pG1 -1; :local pG2 -1; :local pG3 -1; :local pG4 -1
    :local pRouteU -1; :local pRouteM -1
    :local policyOrdinal 0
    :foreach ruleId in=[/ip firewall mangle find] do={
        :if ($ruleId = $inboundU) do={ :set pInboundU $policyOrdinal }
        :if ($ruleId = $inboundM) do={ :set pInboundM $policyOrdinal }
        :if ($ruleId = $bypassLocal) do={ :set pBypassLocal $policyOrdinal }
        :if ($ruleId = $bypassPrivate) do={ :set pBypassPrivate $policyOrdinal }
        :if ($ruleId = $v154c) do={ :set pV154c $policyOrdinal }
        :if ($ruleId = $v154r) do={ :set pV154r $policyOrdinal }
        :if ($ruleId = $v45c) do={ :set pV45c $policyOrdinal }
        :if ($ruleId = $v45r) do={ :set pV45r $policyOrdinal }
        :if ($ruleId = $trackerTcp) do={ :set pTrackerTcp $policyOrdinal }
        :if ($ruleId = $trackerQuic) do={ :set pTrackerQuic $policyOrdinal }
        :if ($ruleId = $pt0) do={ :set pPt0 $policyOrdinal }
        :if ($ruleId = $pt4) do={ :set pPt4 $policyOrdinal }
        :if ($ruleId = $dnsU) do={ :set pDnsU $policyOrdinal }
        :if ($ruleId = $dnsM) do={ :set pDnsM $policyOrdinal }
        :if ($ruleId = $ispU) do={ :set pU $policyOrdinal }
        :if ($ruleId = $ispM) do={ :set pM $policyOrdinal }
        :if ($ruleId = $fallback) do={ :set pFallback $policyOrdinal }
        :if ($ruleId = $gen0) do={ :set pG0 $policyOrdinal }
        :if ($ruleId = $gen1) do={ :set pG1 $policyOrdinal }
        :if ($ruleId = $gen2) do={ :set pG2 $policyOrdinal }
        :if ($ruleId = $gen3) do={ :set pG3 $policyOrdinal }
        :if ($ruleId = $gen4) do={ :set pG4 $policyOrdinal }
        :if ($ruleId = $routeU) do={ :set pRouteU $policyOrdinal }
        :if ($ruleId = $routeM) do={ :set pRouteM $policyOrdinal }
        :set policyOrdinal ($policyOrdinal + 1)
    }
    :if (($pInboundU < 0) || ($pInboundM < 0) || ($pInboundU >= $pBypassLocal) || ($pInboundM >= $pBypassLocal) || \
        ($pBypassLocal < 0) || ($pBypassPrivate < 0) || ($pBypassLocal >= $pBypassPrivate) || \
        ($pBypassPrivate >= $pV154c) || ($pBypassPrivate >= $pV45c) || \
        ($pV154c >= $pV154r) || ($pV154r >= $pV45c) || ($pV45c >= $pV45r) || \
        ($pV45r >= $pTrackerTcp) || ($pTrackerTcp >= $pTrackerQuic) || \
        ($pTrackerQuic >= $pPt0) || ($pPt0 >= $pPt4) || ($pPt4 >= $pDnsU) || \
        ($pDnsU >= $pDnsM) || ($pDnsM >= $pU) || ($pU >= $pM) || \
        ($pM >= $pFallback) || ($pFallback >= $pG0) || ($pG0 >= $pG1) || \
        ($pG1 >= $pG2) || ($pG2 >= $pG3) || ($pG3 >= $pG4) || \
        ($pG4 >= $pRouteU) || ($pRouteU >= $pRouteM)) do={
        :error "routercfg unknown-default-Mobile: mangle priority order changed"
    }

    :local fallbackDisabled [:tostr [/ip firewall mangle get $fallback disabled]]
    :local fallbackMark [:tostr [/ip firewall mangle get $fallback new-connection-mark]]
    :if ($previousMode = "") do={
        :if (($fallbackDisabled = "false") && ($fallbackMark = "conn_unicom") && ($enabledBuckets = 0)) do={
            :set previousMode "Unicom"
        }
        :if (($fallbackDisabled = "true") && ($fallbackMark = "conn_unicom") && ($enabledBuckets = 5)) do={
            :set previousMode "PCC"
        }
        :if ($previousMode = "") do={
            :error "routercfg unknown-default-Mobile: starting fallback/PCC state is mixed or unsupported"
        }

        :local appliedComment $mobileFromUnicom
        :if ($previousMode = "PCC") do={ :set appliedComment $mobileFromPcc }
        /ip firewall mangle set $fallback new-connection-mark=conn_mobile comment=$appliedComment
        /ip firewall mangle enable $fallback
        :foreach ruleId in=$bucketIds do={ /ip firewall mangle disable $ruleId }
    } else={
        :if (($fallbackDisabled != "false") || ($fallbackMark != "conn_mobile") || ($enabledBuckets != 0)) do={
            :error "routercfg unknown-default-Mobile: managed Mobile state is inconsistent"
        }
    }

    :if (([:tostr [/ip firewall mangle get $fallback disabled]] != "false") || \
        ([:tostr [/ip firewall mangle get $fallback new-connection-mark]] != "conn_mobile")) do={
        :error "routercfg unknown-default-Mobile: fallback post-check failed; discard Safe Mode"
    }
    :foreach ruleId in=$bucketIds do={
        :if ([:tostr [/ip firewall mangle get $ruleId disabled]] != "true") do={
            :error "routercfg unknown-default-Mobile: general PCC post-check failed; discard Safe Mode"
        }
    }

    :log warning ("routercfg unknown-default-Mobile active; prior mode=" . $previousMode)
    :put ("Unknown/overlap ordinary destinations now prefer Mobile; prior mode=" . $previousMode . ". VPS A/B remains higher priority. Test NEW connections before committing Safe Mode.")
    } do={
        :local failureText [:tostr $caughtError]
        :log error ("routercfg unknown-default-Mobile FAILED: " . $failureText)
        :put ("routercfg unknown-default-Mobile FAILED: " . $failureText)
        :error $failureText
    }
}
