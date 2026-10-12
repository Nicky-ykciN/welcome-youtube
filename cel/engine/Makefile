# Oercel engine
CC      ?= gcc
CFLAGS  ?= -O3 -march=native -fno-math-errno -fno-trapping-math
CFLAGS  += -std=gnu11 -fopenmp -Wall -Wextra -Wno-unused-parameter
LDLIBS  = -lm

oercel: oercel.c
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

clean:
	rm -f oercel tests/forcetest tests/molforcetest

.PHONY: clean

# The test binaries are ALWAYS rebuilt from source (FORCE, a few seconds each): a stale one, or one
# built on another machine (e.g. with AVX-512 for a CPU without it), must never be run by
# `make test` or tests/validate.sh. They are git-ignored and must never be committed.
tests/forcetest: tests/forcetest.c oercel.c FORCE
	$(CC) $(CFLAGS) -o $@ tests/forcetest.c $(LDLIBS)

tests/molforcetest: tests/molforcetest.c oercel.c FORCE
	$(CC) $(CFLAGS) -o $@ tests/molforcetest.c $(LDLIBS)

FORCE:
.PHONY: FORCE

test: tests/forcetest tests/molforcetest
	./tests/forcetest 12.5
	./tests/forcetest 9
	./tests/forcetest 23.7
	./tests/molforcetest

.PHONY: test
