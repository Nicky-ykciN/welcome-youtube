# Oercel engine
CC      ?= gcc
CFLAGS  ?= -O3 -march=native -fno-math-errno -fno-trapping-math
CFLAGS  += -std=gnu11 -fopenmp -Wall -Wextra -Wno-unused-parameter
LDLIBS  = -lm

oercel: oercel.c
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

clean:
	rm -f oercel tests/forcetest

.PHONY: clean

tests/forcetest: tests/forcetest.c oercel.c
	$(CC) $(CFLAGS) -o $@ tests/forcetest.c $(LDLIBS)

test: tests/forcetest
	./tests/forcetest 12.5
	./tests/forcetest 9
	./tests/forcetest 23.7

.PHONY: test
