#!/bin/bash
# script to list all UniFi devices from the given controller and get some infos
# https://github.com/binarybear-de/cmk_check_unifi-controller
SCRIPTBUILD="BUILD 2021-11-04-v3"

###############################################################
# you should not need to edit anything here - use the config file!
###############################################################

CONFIG_FILE=/etc/check_mk/unifi.cfg
CONFIG_ACCESS=$(stat -c %a $CONFIG_FILE)
CONFIG_OWNER=$(stat -c %U $CONFIG_FILE)

if [ ! $CONFIG_ACCESS = 700 ] || [ ! $CONFIG_OWNER = root ] ; then
        echo "2 UniFi-Controller - Config permission mismatch, must be 700 with owner root (current: $CONFIG_ACCESS, owner $CONFIG_OWNER)!"
        exit 1
fi

# source the settings from file
. $CONFIG_FILE

# init counters and variables
NUM_NOTNAMED=0
NUM_NOTADOPTED=0
STATUS=0

# create the temporary files
COOKIE_FILE=/tmp/unifi-check-cookie

#the curl command used to pull the data from the WebUI
CURL_CMD="curl --silent --cookie ${COOKIE_FILE} --cookie-jar ${COOKIE_FILE} $CURLOPTS"

getDeviceInfo() {
        echo $DEVICES | jq " .data | .[] | select(.serial | contains($1))"
}
getValueFromDevice() {
        # read value, replace spaces with underscores and strip quotes (see issue #7)
        echo $JSON | jq " .$1 " | sed -e 's/ /_/g' | sed -e 's/"//g'
}
getValueFromController() {
        echo $JSON | jq ".data | .[] | .$1" | sed -e 's/"//g'
}

loginController() {
        touch $COOKIE_FILE
        chmod 600 $COOKIE_FILE
        if ! $(${CURL_CMD} --request POST  --data '{\"username\":\"$USERNAME\", \"password\":\"$PASSWORD\"}' $BASEURL/api/auth/login > /dev/null) ; then
                echo "2 UniFi-Controller - Controller unavailable! Login failed or no route to API!"
                exit 1
        fi
}


###############################################################
# block 1: login to controller and get some controller status
###############################################################

# check if there's an existing login cookie - else try to login interactively
if [ ! -e "$COOKIE_FILE" ]; then
        loginController
fi

# get some basic information about the controller - if this fails the cookie may has expired. Then deleting cookie, login again and try again (UGLY)
JSON=$(${CURL_CMD} --request GET  $BASEURL/proxy/network/api/s/default/stat/sysinfo)
if [[ "$JSON" = *"LoginRequired"* ]]; then
        rm $COOKIE_FILE
        loginController
        JSON=$(${CURL_CMD} --request GET  $BASEURL/proxy/network/api/s/default/stat/sysinfo)
fi

if [ "$(getValueFromController update_available)" = "true" ]; then
        BUILD="$BUILD (Update avaiable!)"
        STATUS=$STATUS_UPGRADABLE
fi

#output the controllers version
echo "$STATUS UniFi-Controller - Hostname: $(getValueFromController hostname), Build $(getValueFromController build), Check-Script $SCRIPTBUILD"
###############################################################
# block 2: get every site's configuration
###############################################################

# get a list of all sites on the controller
SITES=$(echo $(${CURL_CMD}  --request GET $BASEURL/proxy/network/api/self/sites) | jq '.data | .[] | .name' | sed -e 's/"//g')

# loop over all sites
for SITE in $SITES; do

        # counter of sites
        ((NUM_SITES=NUM_SITES+1))

        # get all info of all devices of that site as json
        DEVICES=$(${CURL_CMD} --request GET  --data "{}" $BASEURL/proxy/network/api/s/$SITE/stat/device)

        # loop over all serial numbers (devices) on current site
        for SERIAL in $(echo $DEVICES | jq '.data | .[] | .serial'); do

                # select one device
                JSON=$(getDeviceInfo $SERIAL)

                # check if the device is already adopted. if not: set controller's state to warning and skip to next device
                if [ "$(getValueFromDevice adopted)" = "false" ]; then
                        ((NUM_NOTADOPTED=NUM_NOTADOPTED+1))
                        break
                fi

                # increment device counter - only if device is adopted!
                ((NUM_DEVICES=NUM_DEVICES+1))

                # check if the device is 'null' which means it is not named at all and skip to next device
                DEVICE_NAME=$(getValueFromDevice name)
                if [ "$DEVICE_NAME" = "null" ]; then
                        ((NUM_NOTNAMED=NUM_NOTNAMED+1))
                        break
                fi
                # if named and adopted, get more info

                CLIENTS=$(getValueFromDevice num_sta)
                UPGRADEABLEFW=$(getValueFromDevice upgrade_to_firmware)
                VERSION=$(getValueFromDevice version)
                STATE=$(getValueFromDevice state)
                SCORE=$(getValueFromDevice satisfaction)
                LOCATING=$(getValueFromDevice locating)
                STATUS=3 # set the service-state in check_mk, default is unknown if something weird happens

                # determining the device's state
                # https://community.ui.com/questions/Fetching-current-UAP-status/88a197f9-3530-4580-8f0b-eca43b41ba6b
                case $STATE in
                        1)      STATUS=0
                                DESCRIPTION="CONNECTED";;

                        0)      STATUS=2
                                DESCRIPTION="DISCONNECTED!";;

                        4)      STATUS=$STATUS_UPGRADING
                                DESCRIPTION="UPGRADING";;

                        5)      STATUS=$STATUS_PROVISIONING
                                DESCRIPTION="PROVISIONING";;

                        6)      STATUS=$STATUS_HEARTBEAT_MISSED
                                DESCRIPTION="heartbeat missed!";;

                        10)     STATUS=2
                                DESCRIPTION="Adoption failed!";;

                        *)      DESCRIPTION="Unkown state ($STATE)!";;
                esac

                # make a upgrade check
                if [ "$UPGRADEABLEFW" != "$VERSION" ] && [ "$UPGRADEABLEFW" != "null" ]; then
                        VERSION="$VERSION ($UPGRADEABLEFW avaible)"
                        # check if status is "better" than upgradable. Prevent a previous CRIT event to be reduced to WARN simply because device is upgradable...
                        if [ $STATUS -le $STATUS_UPGRADABLE ]; then STATUS=$STATUS_UPGRADABLE; fi
                fi
                if [ "$LOCATING" = "true" ]; then
                        LOCATOR="Locator is enabled!"
                        STATE=1
                fi
                # final output per device including infos and metrics
                if [ "$USE_SITE_PREFIX" = "1" ]; then
                        echo "$STATUS UniFi_$SITE-$DEVICE_NAME clients=$CLIENTS|score=$SCORE;;;-10;100 $DESCRIPTION, Site: $SITE, Clients: $CLIENTS, Firmware: $VERSION"
                else
                        echo "$STATUS UniFi_$DEVICE_NAME clients=$CLIENTS|score=$SCORE;;;-10;100 $DESCRIPTION, Site: $SITE, Clients: $CLIENTS, Firmware: $VERSION"
                fi
        done
done

###############################################################
# block 3: summary of all devices
###############################################################

if [ "$NUM_NOTADOPTED" -eq 0 ] && [ "$NUM_NOTNAMED" -eq 0 ]; then
        echo "0 UniFi-Devices devices=$NUM_DEVICES|sites=$NUM_SITES|unamed=$NUM_NOTNAMED|unadopted=$NUM_NOTADOPTED $NUM_DEVICES devices on $NUM_SITES sites - no unnamed or unadopted devices found"
else
        NUM_NOTADOPTED=$((NUM_NOTADOPTED/NUM_SITES))
        echo "1 UniFi-Devices devices=$NUM_DEVICES|sites=$NUM_SITES|unamed=$NUM_NOTNAMED|unadopted=$NUM_NOTADOPTED $NUM_DEVICES devices on $NUM_SITES sites - found $NUM_NOTNAMED unnamed devices and $NUM_NOTADOPTED unadopted devices!"
fi

###############################################################
