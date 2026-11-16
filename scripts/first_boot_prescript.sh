#!/bin/bash
# DietPi runs this file once, as root, at first boot before the network. It only starts the Wi-Fi
# step of Automation_Custom_Script.sh, which DietPi imports from the card beside it: that step reads
# the Wi-Fi settings and writes DietPi's own Wi-Fi files before DietPi reads them.
exec /bin/bash /boot/Automation_Custom_Script.sh wifi
