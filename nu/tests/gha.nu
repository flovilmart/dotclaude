# Tests for gha.nu (GitHub Actions annotations and job summary)
use std/testing *
use std/assert
use ../gha.nu

const HERE = path self .

@test
def "an annotation carries its properties and escapes them" [] {
  assert equal (gha annotation error "two\nlines 100%" --file "a/b.nu" --line 3 --title "x: y, z") "::error file=a/b.nu,line=3,title=x%3A y%2C z::two%0Alines 100%25"
}

@test
def "an annotation without properties" [] {
  assert equal (gha annotation warning "careful") "::warning::careful"
}

@test
def "the summary is appended to GITHUB_STEP_SUMMARY" [] {
  let f = (mktemp | str trim)
  with-env {GITHUB_STEP_SUMMARY: $f} { gha summary "one"; gha summary "two" }
  assert equal (open --raw $f) "one\ntwo\n"
}

@test
def "without GITHUB_STEP_SUMMARY the summary is a no-op" [] {
  with-env {GITHUB_STEP_SUMMARY: ""} { gha summary "nowhere" }
}

@test
def "enabled only when GITHUB_ACTIONS is true" [] {
  assert equal (with-env {GITHUB_ACTIONS: "true"} { gha enabled }) true
  assert equal (with-env {GITHUB_ACTIONS: "false"} { gha enabled }) false
}

@test
def "the error location is the first repo file in a rendered error" [] {
  let root = ($HERE | path join ../.. | path expand)
  let file = ($HERE | path join ../gha.nu | path expand)
  let rendered = $"Error: x\n  ,-[/usr/lib/elsewhere.nu:9:1]\n  ,-[($file):78:16]\n"
  assert equal (gha error-location $rendered $root) {file: "nu/gha.nu", line: 78}
  assert equal (gha error-location "no location here" $root) null
}

@test
def "a table cell escapes pipes and flattens newlines" [] {
  assert equal (gha cell "a|b\nc") 'a\|b c'
}
