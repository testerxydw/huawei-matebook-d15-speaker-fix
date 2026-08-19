savedcmd_es8316.mod := printf '%s\n'   es8316.o | awk '!x[$$0]++ { print("./"$$0) }' > es8316.mod
