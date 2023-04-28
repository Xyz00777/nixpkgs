{ config, lib, options, pkgs, ... }:

with lib;

let
  cfg = config.services.syncthing;
  opt = options.services.syncthing;
  defaultUser = "syncthing";
  defaultGroup = defaultUser;
  settingsFormat = pkgs.formats.json { };

  devices = mapAttrsToList (_: device: device // {
    deviceID = device.id;
  }) cfg.settings.devices;

  folders = mapAttrsToList (_: folder: folder // {
    devices = map (device:
      if builtins.isString device then
        { deviceId = cfg.devices.${device}.id; }
      else
        device
    ) folder.devices;
  }) cfg.settings.folders;

  updateConfig = pkgs.writers.writeDash "merge-syncthing-config" ''
    set -efu

    # be careful not to leak secrets in the filesystem or in process listings

    umask 0077

    # get the api key by parsing the config.xml
    while
        ! ${pkgs.libxml2}/bin/xmllint \
            --xpath 'string(configuration/gui/apikey)' \
            ${cfg.configDir}/config.xml \
            >"$RUNTIME_DIRECTORY/api_key"
    do sleep 1; done

    (printf "X-API-Key: "; cat "$RUNTIME_DIRECTORY/api_key") >"$RUNTIME_DIRECTORY/headers"

    curl() {
        ${pkgs.curl}/bin/curl -sSLk -H "@$RUNTIME_DIRECTORY/headers" \
            --retry 1000 --retry-delay 1 --retry-all-errors \
            "$@"
    }

    # query the old config
    old_cfg=$(curl ${cfg.guiAddress}/rest/config)

    # generate the new config by merging with the NixOS config options
    new_cfg=$(printf '%s\n' "$old_cfg" | ${pkgs.jq}/bin/jq -c '. * ${builtins.toJSON cfg.settings} * {
        "devices": (${builtins.toJSON devices}${optionalString (cfg.devices == {} || ! cfg.overrideDevices) " + .devices"}),
        "folders": (${builtins.toJSON folders}${optionalString (cfg.folders == {} || ! cfg.overrideFolders) " + .folders"})
    }')

    echo "$new_cfg" | ${pkgs.jq}/bin/jq .

    # send the new config
    curl -X PUT -d "$new_cfg" ${cfg.guiAddress}/rest/config

    # restart Syncthing if required
    if curl ${cfg.guiAddress}/rest/config/restart-required |
       ${pkgs.jq}/bin/jq -e .requiresRestart > /dev/null; then
        curl -X POST ${cfg.guiAddress}/rest/system/restart
    fi
  '';
in {
  ###### interface
  options = {
    services.syncthing = {

      enable = mkEnableOption
        (lib.mdDoc "Syncthing, a self-hosted open-source alternative to Dropbox and Bittorrent Sync");

      cert = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = mdDoc ''
          Path to the `cert.pem` file, which will be copied into Syncthing's
          [configDir](#opt-services.syncthing.configDir).
        '';
      };

      key = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = mdDoc ''
          Path to the `key.pem` file, which will be copied into Syncthing's
          [configDir](#opt-services.syncthing.configDir).
        '';
      };

      overrideDevices = mkOption {
        type = types.bool;
        default = true;
        description = mdDoc ''
          Whether to delete the devices which are not configured via the
          [devices](#opt-services.syncthing.settings.devices) option.
          If set to `false`, devices added via the web
          interface will persist and will have to be deleted manually.
        '';
      };

      overrideFolders = mkOption {
        type = types.bool;
        default = true;
        description = mdDoc ''
          Whether to delete the folders which are not configured via the
          [folders](#opt-services.syncthing.settings.folders) option.
          If set to `false`, folders added via the web
          interface will persist and will have to be deleted manually.
        '';
      };

      settings = mkOption {
        type = types.submodule {
          freeformType = settingsFormat.type;
          options = {
            # global options
            options = mkOption {
              default = {};
              description = mdDoc ''
                The options element contains all other global configuration options
              '';
              type = types.attrsOf (types.submodule ({ name, ... }: {
                freeformType = settingsFormat.type;
                options = {

                  listenAddress = mkOption {
                    type = types.str;
                    default = "default";
                    description = lib.mdDoc ''
                      The listen address for incoming sync connections.
                      See [Listen Addresses](https://docs.syncthing.net/users/config.html#listen-addresses) for the allowed syntax.
                    '';
                  };

                  globalAnnounceServer = mkOption {
                    type = types.str;
                    default = "default";
                    description = lib.mdDoc ''
                      A URI to a global announce (discovery) server, or the word default to include the default servers. Any number of globalAnnounceServer elements may be present.
                      The syntax for non-default entries is that of an HTTP or HTTPS URL.
                      A number of options may be added as query options to the URL: insecure to prevent certificate validation (required for HTTP URLs) and id=<device ID> to perform certificate pinning.
                      The device ID to use is printed by the discovery server on startup.
                      For more information see here: <https://docs.syncthing.net/users/config.html#config-option-options.globalannounceserver>.
                    '';
                  };

                  globalAnnounceEnabled = mkOption {
                    type = types.bool;
                    default = true;
                    description = lib.mdDoc ''
                      Whether to announce this device to the global announce (discovery) server, and also use it to look up other devices.
                    '';
                  };

                  localAnnounceEnabled = mkOption {
                    type = types.bool;
                    default = true;
                    description = lib.mdDoc ''
                      Whether to send announcements to the local LAN, also use such announcements to find other devices.
                    '';
                  };

                  localAnnouncePort = mkOption {
                    type = types.int;
                    default = 21027;
                    description = lib.mdDoc ''
                      The port on which to listen and send IPv4 broadcast announcements to.
                    '';
                  };

                  localAnnounceMCAddr = mkOption {
                    type = types.str;
                    default = "ff12::8384";
                    description = lib.mdDoc ''
                      The group address and port to join and send IPv6 multicast announcements on.
                      See: https://docs.syncthing.net/specs/localdisco-v4.html
                    '';
                  };

                  maxSendKbps = mkOption {
                    type = types.int;
                    default = 0;
                    description = lib.mdDoc ''
                      Outgoing data rate limit, in kibibytes per second.
                    '';
                  };

                  maxRecvKbps = mkOption {
                    type = types.int;
                    default = 0;
                    description = lib.mdDoc ''
                      Incoming data rate limits, in kibibytes per second.
                    '';
                  };

                  reconnectionIntervalS = mkOption {
                    type = types.int;
                    default = 60;
                    description = lib.mdDoc ''
                      The number of seconds to wait between each attempt to connect to currently unconnected devices.
                    '';
                  };

                  relaysEnabled = mkOption {
                    type = types.bool;
                    default = true;
                    description = lib.mdDoc ''
                      When true, relays will be connected to and potentially used for device to device connections.
                    '';
                  };

                  relayReconnectIntervalM = mkOption {
                    type = types.int;
                    default = 10;
                    description = lib.mdDoc ''
                      Sets the interval, in minutes, between relay reconnect attempts.
                    '';
                  };

                  startBrowser = mkOption {
                    type = types.bool;
                    default = true;
                    description = lib.mdDoc ''
                      Whether to attempt to start a browser to show the GUI when Syncthing starts.
                      Per Default enabled. when running as service no brwoser starts even when enabled.
                    '';
                  };

                  natEnabled = mkOption {
                    type = types.bool;
                    default = true;
                    description = lib.mdDoc ''
                      Whether to attempt to perform a UPnP and NAT-PMP port mapping for incoming sync connections.
                    '';
                  };

                  natLeaseMinutes = mkOption {
                    type = types.int;
                    default = 60;
                    description = lib.mdDoc ''
                      Request a lease for this many minutes; zero to request a permanent lease.
                    '';
                  };

                  natRenewalMinutes = mkOption {
                    type = types.int;
                    default = 30;
                    description = lib.mdDoc ''
                      Attempt to renew the lease after this many minutes.
                    '';
                  };

                  natTimeoutSeconds = mkOption {
                    type = types.int;
                    default = 10;
                    description = lib.mdDoc ''
                      When scanning for UPnP devices, wait this long for responses.
                    '';
                  };

                  urAccepted = mkOption {
                    type = types.int;
                    default = 0;
                    description = lib.mdDoc ''
                      Whether the user has accepted to submit anonymous usage data.
                      The default, 0, mean the user has not made a choice, and Syncthing will ask at some point in the future.
                      "-1" means no, a number above zero means that that version of usage reporting has been accepted.
                    '';
                  };

                  urSeen = mkOption {
                    type = types.int;
                    default = 0;
                    description = lib.mdDoc ''
                      The highest usage reporting version that has already been shown in the web GUI.
                    '';
                  };

                  urUniqueID = mkOption {
                    type = types.str;
                    default = "";
                    description = lib.mdDoc ''
                      The unique ID sent together with the usage report. Generated when usage reporting is enabled.
                    '';
                  };

                  urURL = mkOption {
                    type = types.str;
                    default = "https://data.syncthing.net/newdata";
                    description = lib.mdDoc ''
                      The URL to post usage report data to, when enabled.
                    '';
                  };

                  urPostInsecurely = mkOption {
                    type = types.bool;
                    default = false;
                    description = lib.mdDoc ''
                      When true, the UR URL can be http instead of https, or have a self-signed certificate.
                    '';
                  };

                  urInitialDelayS = mkOption {
                    type = types.int;
                    default = 1800;
                    description = lib.mdDoc ''
                      The time to wait from startup for the first usage report to be sent. Allows the system to stabilize before reporting statistics.
                    '';
                  };

                  restartOnWakeup = mkOption {
                    type = types.bool;
                    default = true;
                    description = lib.mdDoc ''
                      Whether to perform a restart of Syncthing when it is detected that we are waking from sleep mode (i.e. an unfolding laptop).
                    '';
                  };

                  autoUpgradeIntervalH = mkOption {
                    type = types.int;
                    default = 0;
                    description = lib.mdDoc ''
                      Check for a newer version after this many hours. Set to 0 to disable automatic upgrades.
                      Set to 0 because its going against update policy of nixos.
                      Default would be "12".
                    '';
                  };

                  upgradeToPreReleases = mkOption {
                    type = types.bool;
                    default = false;
                    description = lib.mdDoc ''
                      If true, automatic upgrades include release candidates.
                    '';
                  };

                  keepTemporariesH = mkOption {
                    type = types.int;
                    default = 24;
                    description = lib.mdDoc ''
                      Keep temporary failed transfers for this many hours.
                      While the temporaries are kept, the data they contain need not be transferred again.
                    '';
                  };

                  cacheIgnoredFiles = mkOption {
                    type = types.bool;
                    default = false;
                    description = lib.mdDoc ''
                      Whether to cache the results of ignore pattern evaluation. Performance at the price of memory.
                      Defaults to false as the cost for evaluating ignores is usually not significant.
                    '';
                  };

                  progressUpdateIntervalS = mkOption {
                    type = types.int;
                    default = 5;
                    description = lib.mdDoc ''
                      How often in seconds the progress of ongoing downloads is made available to the GUI.
                    '';
                  };

                  limitBandwidthInLan = mkOption {
                    type = types.bool;
                    default = false;
                    description = lib.mdDoc ''
                      Whether to apply bandwidth limits to devices in the same broadcast domain as the local device.
                    '';
                  };

                  releasesURL = mkOption {
                    type = types.str;
                    default = "https://upgrades.syncthing.net/meta.json";
                    description = lib.mdDoc ''
                      The URL from which release information is loaded, for automatic upgrades.
                    '';
                  };

                  overwriteRemoteDeviceNamesOnConnect = mkOption {
                    type = types.bool;
                    default = false;
                    description = lib.mdDoc ''
                      If set, device names will always be overwritten with the name given by remote on each connection.
                      By default, the name that the remote device announces will only be adopted when a name has not already been set.
                    '';
                  };

                  tempIndexMinBlocks = mkOption {
                    type = types.int;
                    default = 10;
                    description = lib.mdDoc ''
                      When exchanging index information for incomplete transfers, only take into account files that have at least this many blocks.
                    '';
                  };

                  unackedNotificationID = mkOption {
                    type = types.str;
                    default = "authenticationUserAndPassword";
                    description = mdDoc ''
                      ID of a notification to be displayed in the web GUI. Will be removed once the user acknowledged it (e.g. an transition notice on an upgrade).
                    '';
                  };

                  trafficClass = mkOption {
                    type = types.int;
                    default = 0;
                    description = lib.mdDoc ''
                      Specify a type of service (TOS)/traffic class of outgoing packets.
                    '';
                  };

                  setLowPriority = mkOption {
                    type = types.bool;
                    default = true;
                    description = lib.mdDoc ''
                      Syncthing will attempt to lower its process priority at startup.
                      Specifically: on Linux, set itself to a separate process group, set the niceness level of that process group to nine and the I/O priority to best effort level five;
                      on other Unixes, set the process niceness level to nine;
                      on Windows, set the process priority class to below normal.
                      To disable this behavior, for example to control process priority yourself as part of launching Syncthing, set this option to false.
                    '';
                  };

                  maxFolderConcurrency = mkOption {
                    type = types.int;
                    default = 0;
                    description = lib.mdDoc ''
                      This option controls how many folders may concurrently be in I/O-intensive operations such as syncing or scanning.
                      The mechanism is described in detail in a [separate chapter](https://docs.syncthing.net/advanced/option-max-concurrency.html).
                    '';
                  };

                  crashReportingURL = mkOption {
                    type = types.str;
                    default = "https://crash.syncthing.net/newcrash";
                    description = lib.mdDoc ''
                      Server URL where automatic crash reports will be sent if enabled.
                      More Information here: <https://docs.syncthing.net/users/crashrep.html>
                    '';
                  };

                  crashReportingEnabled = mkOption {
                    type = types.bool;
                    default = true;
                    description = lib.mdDoc ''
                      Switch to opt out from the [automatic crash reporting](https://docs.syncthing.net/users/crashrep.html) feature.
                      Set false to keep Syncthing from sending panic logs on serious troubles.
                      Defaults to true, to help the developers troubleshoot.
                    '';
                  };

                  stunKeepaliveStartS = mkOption {
                    type = types.int;
                    default = 180;
                    description = lib.mdDoc ''
                      Interval in seconds between contacting a STUN server to maintain NAT mapping.
                      Default is 24 and you can set it to 0 to disable contacting STUN servers.
                      The interval is automatically reduced if needed, down to a minimum of stunKeepaliveMinS.
                    '';
                  };

                  stunKeepaliveMinS = mkOption {
                    type = types.int;
                    default = 20;
                    description = lib.mdDoc ''
                      Minimum for the stunKeepaliveStartS interval, in seconds.
                    '';
                  };

                  stunServer = mkOption {
                    type = types.str;
                    default = "default";
                    description = lib.mdDoc ''
                      Server to be used for STUN, given as ip:port. The keyword default gets expanded to multiple.
                      More Inforamtione here: <https://docs.syncthing.net/users/config.html#config-option-options.stunserver>.
                    '';
                  };

                  databaseTuning = mkOption {
                    type = types.enum [ "auto" "large" "small"];
                    default = "auto";
                    description = lib.mdDoc ''
                      Controls how Syncthing uses the backend key-value database that stores the index data and other persistent data it needs.
                      The available options and implications are explained in a [separate chapter](https://docs.syncthing.net/advanced/option-database-tuning.html).
                    '';
                  };

                  maxConcurrentIncomingRequestKiB = mkOption {
                    type = types.int;
                    default = 0;
                    description = lib.mdDoc ''
                      This limits how many bytes we have “in the air” in the form of response data being read and processed.
                    '';
                  };

                  announceLANAddresses = mkOption {
                    type = types.bool;
                    default = true;
                    description = lib.mdDoc ''
                      Enable (the default) or disable announcing private (RFC1918) LAN IP addresses to global discovery.
                    '';
                  };

                  sendFullIndexOnUpgrade = mkOption {
                    type = types.bool;
                    default = false;
                    description = lib.mdDoc ''
                      Controls whether all index data is resent when an upgrade has happened, equivalent to starting Syncthing with --reset-deltas.
                      This used to be the default behavior in older versions, but is mainly useful as a troubleshooting step and causes high database churn.
                      The default is now false.
                    '';
                  };

                  connectionLimitEnough = mkOption {
                    type = types.int;
                    default = 0;
                    description = lib.mdDoc ''
                      The number of connections at which we stop trying to connect to more devices, zero meaning no limit. Does not affect incoming connections.
                      The mechanism is described in detail in a [separate chapter](https://docs.syncthing.net/advanced/option-connection-limits.html).
                    '';
                  };

                  connectionLimitMax = mkOption {
                    type = types.int;
                    default = 0;
                    description = lib.mdDoc ''
                      The maximum number of connections which we will allow in total, zero meaning no limit.
                      Affects incoming connections and prevents attempting outgoing connections.
                      The mechanism is described in detail in a [separate chapter](https://docs.syncthing.net/advanced/option-connection-limits.html).
                    '';
                  };

                  insecureAllowOldTLSVersions = mkOption {
                    type = types.bool;
                    default = false;
                    description = lib.mdDoc ''
                      Only for compatibility with old versions of Syncthing on remote devices, as detailed in [insecureAllowOldTLSVersions](https://docs.syncthing.net/advanced/option-insecure-allow-old-tls-versions.html).
                    '';
                  };

                };
              }));
            };

            # device settings
            devices = mkOption {
              default = {};
              description = mdDoc ''
                Peers/devices which Syncthing should communicate with.

                Note that you can still add devices manually, but those changes
                will be reverted on restart if [overrideDevices](#opt-services.syncthing.overrideDevices)
                is enabled.
              '';
              example = {
                bigbox = {
                  id = "7CFNTQM-IMTJBHJ-3UWRDIU-ZGQJFR6-VCXZ3NB-XUH3KZO-N52ITXR-LAIYUAU";
                  addresses = [ "tcp://192.168.0.10:51820" ];
                };
              };
              type = types.attrsOf (types.submodule ({ name, ... }: {
                freeformType = settingsFormat.type;
                options = {

                  name = mkOption {
                    type = types.str;
                    default = name;
                    description = lib.mdDoc ''
                      The name of the device.
                    '';
                  };

                  addresses = mkOption {
                    type = types.listOf types.str;
                    default = [];
                    description = lib.mdDoc ''
                      The addresses used to connect to the device.
                      If this is left empty, dynamic configuration is attempted.
                    '';
                  };

                  id = mkOption {
                    type = types.str;
                    description = mdDoc ''
                      The device ID. See <https://docs.syncthing.net/dev/device-ids.html>.
                    '';
                  };

                  introducer = mkOption {
                    type = types.bool;
                    default = false;
                    description = mdDoc ''
                      Whether the device should act as an introducer and be allowed
                      to add folders on this computer.
                      See <https://docs.syncthing.net/users/introducer.html>.
                    '';
                  };

                  autoAcceptFolders = mkOption {
                    type = types.bool;
                    default = false;
                    description = mdDoc ''
                      Automatically create or share folders that this device advertises at the default path.
                      See <https://docs.syncthing.net/users/config.html?highlight=autoaccept#config-file-format>.
                    '';
                  };

                };
              }));
            };

            # folder settings
            folders = mkOption {
              default = {};
              description = mdDoc ''
                Folders which should be shared by Syncthing.

                Note that you can still add folders manually, but those changes
                will be reverted on restart if [overrideFolders](#opt-services.syncthing.overrideFolders)
                is enabled.
              '';
              example = literalExpression ''
                {
                  "/home/user/sync" = {
                    id = "syncme";
                    devices = [ "bigbox" ];
                  };
                }
              '';
              type = types.attrsOf (types.submodule ({ name, ... }: {
                freeformType = settingsFormat.type;
                options = {

                  enable = mkOption {
                    type = types.bool;
                    default = true;
                    description = lib.mdDoc ''
                      Whether to share this folder.
                      This option is useful when you want to define all folders
                      in one place, but not every machine should share all folders.
                    '';
                  };

                  path = mkOption {
                    # TODO for release 23.05: allow relative paths again and set
                    # working directory to cfg.dataDir
                    type = types.str // {
                      check = x: types.str.check x && (substring 0 1 x == "/" || substring 0 2 x == "~/");
                      description = types.str.description + " starting with / or ~/";
                    };
                    default = name;
                    description = lib.mdDoc ''
                      The path to the folder which should be shared.
                      Only absolute paths (starting with `/`) and paths relative to
                      the [user](#opt-services.syncthing.user)'s home directory
                      (starting with `~/`) are allowed.
                    '';
                  };

                  id = mkOption {
                    type = types.str;
                    default = name;
                    description = lib.mdDoc ''
                      The ID of the folder. Must be the same on all devices.
                    '';
                  };

                  label = mkOption {
                    type = types.str;
                    default = name;
                    description = lib.mdDoc ''
                      The label of the folder.
                    '';
                  };

                  devices = mkOption {
                    type = types.listOf types.str;
                    default = [];
                    description = mdDoc ''
                      The devices this folder should be shared with. Each device must
                      be defined in the [devices](#opt-services.syncthing.settings.devices) option.
                    '';
                  };

                  versioning = mkOption {
                    default = null;
                    description = mdDoc ''
                      How to keep changed/deleted files with Syncthing.
                      There are 4 different types of versioning with different parameters.
                      See <https://docs.syncthing.net/users/versioning.html>.
                    '';
                    example = literalExpression ''
                      [
                        {
                          versioning = {
                            type = "simple";
                            params.keep = "10";
                          };
                        }
                        {
                          versioning = {
                            type = "trashcan";
                            params.cleanoutDays = "1000";
                          };
                        }
                        {
                          versioning = {
                            type = "staggered";
                            fsPath = "/syncthing/backup";
                            params = {
                              cleanInterval = "3600";
                              maxAge = "31536000";
                            };
                          };
                        }
                        {
                          versioning = {
                            type = "external";
                            params.versionsPath = pkgs.writers.writeBash "backup" '''
                              folderpath="$1"
                              filepath="$2"
                              rm -rf "$folderpath/$filepath"
                            ''';
                          };
                        }
                      ]
                    '';
                    type = with types; nullOr (submodule {
                      options = {
                        type = mkOption {
                          type = enum [ "external" "simple" "staggered" "trashcan" ];
                          description = mdDoc ''
                            The type of versioning.
                            See <https://docs.syncthing.net/users/versioning.html>.
                          '';
                        };
                        fsPath = mkOption {
                          default = "";
                          type = either str path;
                          description = mdDoc ''
                            Path to the versioning folder.
                            See <https://docs.syncthing.net/users/versioning.html>.
                          '';
                        };
                        params = mkOption {
                          type = attrsOf (either str path);
                          description = mdDoc ''
                            The parameters for versioning. Structure depends on
                            [versioning.type](#opt-services.syncthing.settings.folders._name_.versioning.type).
                            See <https://docs.syncthing.net/users/versioning.html>.
                          '';
                        };
                      };
                    });
                  };

                  rescanInterval = mkOption {
                    type = types.int;
                    default = 3600;
                    description = lib.mdDoc ''
                      How often the folder should be rescanned for changes.
                    '';
                  };

                  type = mkOption {
                    type = types.enum [ "sendreceive" "sendonly" "receiveonly" "receiveencrypted" ];
                    default = "sendreceive";
                    description = lib.mdDoc ''
                      Whether to only send changes for this folder, only receive them
                      or both. `receiveencrypted` can be used for untrusted devices. See
                      <https://docs.syncthing.net/users/untrusted.html> for reference.
                    '';
                  };

                  watch = mkOption {
                    type = types.bool;
                    default = true;
                    description = lib.mdDoc ''
                      Whether the folder should be watched for changes by inotify.
                    '';
                  };

                  watchDelay = mkOption {
                    type = types.int;
                    default = 10;
                    description = lib.mdDoc ''
                      The delay after an inotify event is triggered.
                    '';
                  };

                  ignorePerms = mkOption {
                    type = types.bool;
                    default = true;
                    description = lib.mdDoc ''
                      Whether to ignore permission changes.
                    '';
                  };

                  ignoreDelete = mkOption {
                    type = types.bool;
                    default = false;
                    description = mdDoc ''
                      Whether to skip deleting files that are deleted by peers.
                      See <https://docs.syncthing.net/advanced/folder-ignoredelete.html>.
                    '';
                  };

                  copiers = mkOption {
                    type = types.int;
                    default = 0;
                    description = mdDoc ''
                      The number of copier and hasher routines to use, or 0 for the system determined optimums.
                      These are low-level performance options for advanced users only;
                      do not change unless requested to or you’ve actually read and understood the code yourself.
                    '';
                  };

                  pullerMaxPendingKiB = mkOption {
                    type = types.int;
                    default = 0;
                    description = mdDoc ''
                      Controls when we stop sending requests to other devices once we’ve got this much unserved requests.
                      The number of pullers is automatically adjusted based on this desired amount of outstanding request data.
                    '';
                  };

                  hashers = mkOption {
                    type = types.int;
                    default = 0;
                    description = mdDoc ''
                      The number of copier and hasher routines to use, or 0 for the system determined optimums.
                      These are low-level performance options for advanced users only;
                      do not change unless requested to or you’ve actually read and understood the code yourself.
                    '';
                  };

                  order = mkOption {
                    type = types.enum [ "random" "alphabetic" "smallestFirst" "largestFirst" "oldestFirst" "newestFirst" ];
                    default = "random";
                    description = mdDoc ''
                      The order in which needed files should be pulled from the cluster. It has no effect when the folder type is “send only”. The possibles values are:
                        ``random`` (default)
                          Pull files in random order. This optimizes for balancing resources among the devices in a cluster.
                        ``alphabetic``
                          Pull files ordered by file name alphabetically.
                        ``smallestFirst``, ``largestFirst``
                          Pull files ordered by file size; smallest and largest first respectively.
                        ``oldestFirst``, ``newestFirst``
                          Pull files ordered by modification time; oldest and newest first respectively.
                      Note that the scanned files are sent in batches and the sorting is applied only to the already discovered files.
                      This means the sync might start with a 1 GB file even if there is 1 KB file available on the source device until the 1 KB becomes known to the pulling device
                    '';
                  };

                  scanProgressIntervalS = mkOption {
                    type = types.int;
                    default = 0;
                    description = mdDoc ''
                      The interval in seconds with which scan progress information is sent to the GUI.
                      Setting to 0 will cause Syncthing to use the default value of two.
                    '';
                  };

                  pullerPauseS = mkOption {
                    type = types.int;
                    default = 0;
                    description = mdDoc ''
                      Tweak for rate limiting the puller when it retries pulling files.
                      Don’t change this unless you know what you’re doing.
                    '';
                  };

                  maxConflicts = mkOption {
                    type = types.int;
                    default = -1;
                    description = mdDoc ''
                      The maximum number of conflict copies to keep around for any given file.
                      The default, -1, means an unlimited number.
                      Setting this to 0 disables conflict copies altogether.
                    '';
                  };

                  disableSparseFiles = mkOption {
                    type = types.bool;
                    default = false;
                    description = mdDoc ''
                      By default, blocks containing all zeros are not written, causing files to be sparse on filesystems that support this feature.
                      When set to true, sparse files will not be created.
                    '';
                  };

                  disableTempIndexes = mkOption {
                    type = types.bool;
                    default = false;
                    description = mdDoc ''
                      By default, devices exchange information about blocks available in transfers that are still in progress, which allows other devices to download parts of files that are not yet fully downloaded on your own device, essentially making transfers more torrent like.
                      When set to true, such information is not exchanged for this folder.
                    '';
                  };

                  weakHashThresholdPct = mkOption {
                    type = types.int;
                    default = 25;
                    description = mdDoc ''
                      Use weak hash if more than the given percentage of the file has changed.
                      Set to -1 to always use weak hash. Default is 25
                    '';
                  };

                  markerName = mkOption {
                    type = types.str;
                    default = ".stfolder";
                    description = mdDoc ''
                      Name of a directory or file in the folder root to be used as [How do I serve a folder from a read only filesystem](https://docs.syncthing.net/users/faq.html#marker-faq)?.
                      Default is .stfolder.
                    '';
                  };

                  copyOwnershipFromParent = mkOption {
                    type = types.bool;
                    default = false;
                    description = mdDoc ''
                      On Unix systems, tries to copy file/folder ownership from the parent directory (the directory it’s located in).
                      Requires running Syncthing as a privileged user, or granting it additional capabilities (e.g. CAP_CHOWN on Linux).
                    '';
                  };

                  modTimeWindowS = mkOption {
                    type = types.int;
                    default = 0;
                    description = mdDoc ''
                      Allowed modification timestamp difference when comparing files for equivalence.
                      To be used on file systems which have unstable modification timestamps that might change after being recorded during the last write operation.
                      Default is 2 on Android when the folder is located on a FAT partition, and 0 otherwise.
                    '';
                  };

                  maxConcurrentWrites = mkOption {
                    type = types.int;
                    default = 2;
                    description = mdDoc ''
                      Allowed modification timestamp difference when comparing files for equivalence.
                      To be used on file systems which have unstable modification timestamps that might change after being recorded during the last write operation.
                      Default is 2 on Android when the folder is located on a FAT partition, and 0 otherwise.
                    '';
                  };

                  disableFsync = mkOption {
                    type = types.bool;
                    default = false;
                    description = mdDoc ''
                      Warning
                      This is a known insecure option - use at your own risk.
                      Disables committing file operations to disk before recording them in the database.
                      Disabling fsync can lead to data corruption.
                      The mechanism is described in a [separate chapter](https://docs.syncthing.net/advanced/folder-disable-fsync.html).
                    '';
                  };

                  blockPullOrder = mkOption {
                    type = types.enum [ "standard" "random" "inOrder" ];
                    default = "standard";
                    description = mdDoc ''
                      Order in which the blocks of a file are downloaded. This option controls how quickly different parts of the file spread between the connected devices, at the cost of causing strain on the storage.
                      Available options:
                      standard (default)
                      The blocks of a file are split into N equal continuous sequences, where N is the number of connected devices. Each device starts downloading its own sequence, after which it picks other devices sequences at random. Provides acceptable data distribution and minimal spinning disk strain.
                      random
                      The blocks of a file are downloaded in a random order. Provides great data distribution, but very taxing on spinning disk drives.
                      inOrder
                      The blocks of a file are downloaded sequentially, from start to finish. Spinning disk drive friendly, but provides no improvements to data distribution.
                    '';
                  };

                  copyRangeMethod = mkOption {
                    type = types.enum [ "standard" "copy_file_range" "ioctl" "ioctl" "ioctl" "all" ];
                    default = "standard";
                    description = mdDoc ''
                      Provides a choice of method for copying data between files.
                      This can be used to optimise copies on network filesystems, improve speed of large copies or clone the data using copy-on-write functionality if the underlying filesystem supports it.
                      The mechanism is described in a [separate chapter](https://docs.syncthing.net/advanced/folder-copyrangemethod.html).
                    '';
                  };

                  caseSensitiveFS = mkOption {
                    type = types.bool;
                    default = false;
                    description = mdDoc ''
                      Affects performance by disabling the extra safety checks for case insensitive filesystems.
                      The mechanism and how to set it up is described in a [separate chapter](https://docs.syncthing.net/advanced/folder-caseSensitiveFS.html).
                    '';
                  };

                  junctionsAsDirs = mkOption {
                    type = types.bool;
                    default = false;
                    description = mdDoc ''
                      NTFS directory junctions are treated as ordinary directories, if this is set to true.
                    '';
                  };

                  syncOwnership = mkOption {
                    type = types.bool;
                    default = false;
                    description = mdDoc ''
                      File and directory ownership is synced when this is set to true.
                      See [syncOwnership](https://docs.syncthing.net/advanced/folder-sync-ownership.html) for more information.
                    '';
                  };

                  sendOwnership = mkOption {
                    type = types.bool;
                    default = false;
                    description = mdDoc ''
                      File and directory ownership information is scanned when this is set to true.
                      See [sendOwnership](https://docs.syncthing.net/advanced/folder-send-ownership.html) for more information.
                    '';
                  };

                  syncXattrs = mkOption {
                    type = types.bool;
                    default = false;
                    description = mdDoc ''
                      File and directory extended attributes are synced when this is set to true.
                      See [syncXattrs](https://docs.syncthing.net/advanced/folder-sync-xattrs.html) for more information.
                    '';
                  };

                  sendXattrs = mkOption {
                    type = types.bool;
                    default = false;
                    description = mdDoc ''
                      File and directory extended attributes are scanned and sent to other devices when this is set to true.
                      See [sendXattrs](https://docs.syncthing.net/advanced/folder-send-xattrs.html) for more information.
                    '';
                  };

                };
              }));
            };

          };
        };
        default = {};
        description = mdDoc ''
          Extra configuration options for Syncthing.
          See <https://docs.syncthing.net/users/config.html>.
          Note that this attribute set does not exactly match the documented
          xml format. Instead, this is the format of the json rest api. There
          are slight differences. For example, this xml:
          ```xml
          <options>
            <listenAddress>default</listenAddress>
            <minHomeDiskFree unit="%">1</minHomeDiskFree>
          </options>
          ```
          corresponds to the json:
          ```json
          {
            options: {
              listenAddresses = [
                "default"
              ];
              minHomeDiskFree = {
                unit = "%";
                value = 1;
              };
            };
          }
          ```
        '';
        example = {
          options.localAnnounceEnabled = false;
          gui.theme = "black";
        };
      };

      guiAddress = mkOption {
        type = types.str;
        default = "127.0.0.1:8384";
        description = lib.mdDoc ''
          The address to serve the web interface at.
        '';
      };

      systemService = mkOption {
        type = types.bool;
        default = true;
        description = lib.mdDoc ''
          Whether to auto-launch Syncthing as a system service.
        '';
      };

      user = mkOption {
        type = types.str;
        default = defaultUser;
        example = "yourUser";
        description = mdDoc ''
          The user to run Syncthing as.
          By default, a user named `${defaultUser}` will be created whose home
          directory is [dataDir](#opt-services.syncthing.dataDir).
        '';
      };

      group = mkOption {
        type = types.str;
        default = defaultGroup;
        example = "yourGroup";
        description = mdDoc ''
          The group to run Syncthing under.
          By default, a group named `${defaultGroup}` will be created.
        '';
      };

      all_proxy = mkOption {
        type = with types; nullOr str;
        default = null;
        example = "socks5://address.com:1234";
        description = mdDoc ''
          Overwrites the all_proxy environment variable for the Syncthing process to
          the given value. This is normally used to let Syncthing connect
          through a SOCKS5 proxy server.
          See <https://docs.syncthing.net/users/proxying.html>.
        '';
      };

      dataDir = mkOption {
        type = types.path;
        default = "/var/lib/syncthing";
        example = "/home/yourUser";
        description = lib.mdDoc ''
          The path where synchronised directories will exist.
        '';
      };

      configDir = let
        cond = versionAtLeast config.system.stateVersion "19.03";
      in mkOption {
        type = types.path;
        description = lib.mdDoc ''
          The path where the settings and keys will exist.
        '';
        default = cfg.dataDir + optionalString cond "/.config/syncthing";
        defaultText = literalMD ''
          * if `stateVersion >= 19.03`:

                config.${opt.dataDir} + "/.config/syncthing"
          * otherwise:

                config.${opt.dataDir}
        '';
      };

      extraFlags = mkOption {
        type = types.listOf types.str;
        default = [];
        example = [ "--reset-deltas" ];
        description = lib.mdDoc ''
          Extra flags passed to the syncthing command in the service definition.
        '';
      };

      openDefaultPorts = mkOption {
        type = types.bool;
        default = false;
        example = true;
        description = lib.mdDoc ''
          Whether to open the default ports in the firewall: TCP/UDP 22000 for transfers
          and UDP 21027 for discovery.

          If multiple users are running Syncthing on this machine, you will need
          to manually open a set of ports for each instance and leave this disabled.
          Alternatively, if you are running only a single instance on this machine
          using the default ports, enable this.
        '';
      };

      package = mkOption {
        type = types.package;
        default = pkgs.syncthing;
        defaultText = literalExpression "pkgs.syncthing";
        description = lib.mdDoc ''
          The Syncthing package to use.
        '';
      };
    };
  };

  imports = [
    (mkRemovedOptionModule [ "services" "syncthing" "useInotify" ] ''
      This option was removed because Syncthing now has the inotify functionality included under the name "fswatcher".
      It can be enabled on a per-folder basis through the web interface.
    '')
    (mkRenamedOptionModule [ "services" "syncthing" "extraOptions" ] [ "services" "syncthing" "settings" ])
    (mkRenamedOptionModule [ "services" "syncthing" "folders" ] [ "services" "syncthing" "settings" "folders" ])
    (mkRenamedOptionModule [ "services" "syncthing" "devices" ] [ "services" "syncthing" "settings" "devices" ])
    (mkRenamedOptionModule [ "services" "syncthing" "options" ] [ "services" "syncthing" "settings" "options" ])
  ] ++ map (o:
    mkRenamedOptionModule [ "services" "syncthing" "declarative" o ] [ "services" "syncthing" o ]
  ) [ "cert" "key" "devices" "folders" "overrideDevices" "overrideFolders" "extraOptions"];

  ###### implementation

  config = mkIf cfg.enable {

    networking.firewall = mkIf cfg.openDefaultPorts {
      allowedTCPPorts = [ 22000 ];
      allowedUDPPorts = [ 21027 22000 ];
    };

    systemd.packages = [ pkgs.syncthing ];

    users.users = mkIf (cfg.systemService && cfg.user == defaultUser) {
      ${defaultUser} =
        { group = cfg.group;
          home  = cfg.dataDir;
          createHome = true;
          uid = config.ids.uids.syncthing;
          description = "Syncthing daemon user";
        };
    };

    users.groups = mkIf (cfg.systemService && cfg.group == defaultGroup) {
      ${defaultGroup}.gid =
        config.ids.gids.syncthing;
    };

    systemd.services = {
      # upstream reference:
      # https://github.com/syncthing/syncthing/blob/main/etc/linux-systemd/system/syncthing%40.service
      syncthing = mkIf cfg.systemService {
        description = "Syncthing service";
        after = [ "network.target" ];
        environment = {
          STNORESTART = "yes";
          STNOUPGRADE = "yes";
          inherit (cfg) all_proxy;
        } // config.networking.proxy.envVars;
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Restart = "on-failure";
          SuccessExitStatus = "3 4";
          RestartForceExitStatus="3 4";
          User = cfg.user;
          Group = cfg.group;
          ExecStartPre = mkIf (cfg.cert != null || cfg.key != null)
            "+${pkgs.writers.writeBash "syncthing-copy-keys" ''
              install -dm700 -o ${cfg.user} -g ${cfg.group} ${cfg.configDir}
              ${optionalString (cfg.cert != null) ''
                install -Dm400 -o ${cfg.user} -g ${cfg.group} ${toString cfg.cert} ${cfg.configDir}/cert.pem
              ''}
              ${optionalString (cfg.key != null) ''
                install -Dm400 -o ${cfg.user} -g ${cfg.group} ${toString cfg.key} ${cfg.configDir}/key.pem
              ''}
            ''}"
          ;
          ExecStart = ''
            ${cfg.package}/bin/syncthing \
              -no-browser \
              -gui-address=${cfg.guiAddress} \
              -home=${cfg.configDir} ${escapeShellArgs cfg.extraFlags}
          '';
          MemoryDenyWriteExecute = true;
          NoNewPrivileges = true;
          PrivateDevices = true;
          PrivateMounts = true;
          PrivateTmp = true;
          PrivateUsers = true;
          ProtectControlGroups = true;
          ProtectHostname = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          RestrictNamespaces = true;
          RestrictRealtime = true;
          RestrictSUIDSGID = true;
          CapabilityBoundingSet = [
            "~CAP_SYS_PTRACE" "~CAP_SYS_ADMIN"
            "~CAP_SETGID" "~CAP_SETUID" "~CAP_SETPCAP"
            "~CAP_SYS_TIME" "~CAP_KILL"
          ];
        };
      };
      syncthing-init = mkIf (
        cfg.devices != {} || cfg.folders != {} || cfg.extraOptions != {}
      ) {
        description = "Syncthing configuration updater";
        requisite = [ "syncthing.service" ];
        after = [ "syncthing.service" ];
        wantedBy = [ "multi-user.target" ];

        serviceConfig = {
          User = cfg.user;
          RemainAfterExit = true;
          RuntimeDirectory = "syncthing-init";
          Type = "oneshot";
          ExecStart = updateConfig;
        };
      };

      syncthing-resume = {
        wantedBy = [ "suspend.target" ];
      };
    };
  };
}
