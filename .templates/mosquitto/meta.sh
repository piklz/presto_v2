#!/usr/bin/env bash
# templates/mosquitto/meta.sh
#
# Presto template metadata

SERVICE_DESC="MQTT broker"
SERVICE_ICON="📡"
SERVICE_ARCH="all"
SERVICE_CONFIGS="config/mosquitto.conf"   # seeded once, stays REAL_USER-owned
