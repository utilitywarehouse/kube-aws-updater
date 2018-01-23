#!/bin/sh

RED='\033[0;31m'
BLUE='\033[0;34m'
GREEN='\033[1;32m'
NC='\033[0m' # No Color

log() {
  ts=$(date +"%Y-%m-%dT%H:%M:%SZ")
  printf "${1}${ts} ${2}${NC}\n"
}
