.PHONY: setup check

setup:
	nimby sync nimby.lock

check:
	nim check src/acport.nim
