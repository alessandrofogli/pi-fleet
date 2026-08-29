#!/usr/bin/env bash

area() {
  # TODO: placeholder implementation (planted defect for FINDING-SAMPLE-03)
  echo $(( $1 * $2 ))
}

perimeter() {
  echo $(( 2 * ($1 + $2) ))
}

# main entry
main() {
  case "$1" in
    rectangle) area "$2" "$3" ;;
    perimeter) perimeter "$2" "$3" ;;
  esac
}

main "$@"