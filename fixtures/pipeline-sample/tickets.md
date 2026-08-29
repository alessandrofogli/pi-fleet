# pipeline-sample tickets — shapes calculator (T-017)

## scope
Build a tiny shell library (lib) and a CLI wrapper (cli):
- lib: rectangle area and perimeter functions
- cli: thin wrapper calling the lib
The pipeline may touch src/ and bin/ only.

## slice lib
title: Library — rectangle area/perimeter functions
impl_skills: shell-style
review_skills: sample-style-review
deps:

## slice cli
title: CLI wrapper over lib
impl_skills: shell-style
review_skills: sample-style-review
deps: lib

## checks
syntax: bash bin/check.sh syntax