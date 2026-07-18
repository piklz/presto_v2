#!/usr/bin/env bash
# updates reinstalls if needed
if command -v docker &> /dev/null && [[ $(docker compose version | grep "Docker Compose version v2" -c) -eq 1 ]]; then

  echo -e  "\n\e[32;1m Docker Compose plugin is installed we can UPDATE"

  DCV=$(docker compose version)

  echo  ""
  echo  -e "\e[32;1m Current: $DCV \e[0m"

  echo  -e "\e[33;1m    Stopping Docker compose plugin v2 \e[0m"
  docker compose down

  echo  -e "\e[33;1m    Removing Docker Compose v2 \e[0m"
  #sudo apt remove docker-compose-plugin -y &> /dev/null

  echo  -e "\e[33;1m    UPDATING  Installing new Docker-compose-plugin v2 \e[0m"

  sudo apt install -y docker-compose-plugin &> /dev/null

  echo  -e "\e[33;1m    Starting PRESTO compose stack up again\e[0m"
  docker compose up -d

  DCV=$(docker compose version)
  echo  -e "\e[32;1m     new: $DCV\e[0m"
  echo  ""

else
  echo -e "\n\e[32;1m Docker Compose plugin NOT installed LETS INSTALL IT NOW" 
  sudo apt install -y docker-compose-plugin #&> /dev/null
  DCV=$(docker compose version)
  echo  -e "\e[32;1m Current: $DCV \e[0m"
fi
