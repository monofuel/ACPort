import std/os

switch("path", thisDir() / "../src")
let memoryManager = getEnv("ACPORT_TEST_MM")
if memoryManager.len > 0:
  switch("mm", memoryManager)
