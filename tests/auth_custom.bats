load 'helpers/auth_setup'

setup()    { auth_setup_common; }
teardown() { auth_teardown_common; }

@test "custom create prints 'not implemented' to stderr and exits 64" {
  run scripts/auth/custom.sh create volk
  [ "${status}" -eq 64 ]
  [[ "${output}" == *"not implemented"* ]]
  [[ "${output}" == *"README"* ]]
}

@test "custom store also not implemented" {
  run scripts/auth/custom.sh store volk /tmp/whatever
  [ "${status}" -eq 64 ]
}

@test "custom status prints present=false with backend=custom" {
  run scripts/auth/custom.sh status volk
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"backend=custom"* ]]
  [[ "${output}" == *"present=false"* ]]
}

@test "custom exec exits 64 (no token machinery)" {
  run scripts/auth/custom.sh exec volk -- env
  [ "${status}" -eq 64 ]
}

@test "custom rotate / destroy also stubbed" {
  run scripts/auth/custom.sh rotate volk
  [ "${status}" -eq 64 ]
  run scripts/auth/custom.sh destroy volk
  [ "${status}" -eq 64 ]
}
