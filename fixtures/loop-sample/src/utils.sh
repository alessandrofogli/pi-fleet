#!/usr/bin/env bash
# parse utilities for the shapes calculator
set -u

# numeric test
is_number() {
  [[ "$1" =~ ^[0-9]+$ ]]
}