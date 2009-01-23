SOURCE_DIR=src
BINARY_DIR=ebin

SOURCES=$(wildcard $(SOURCE_DIR)/*.erl)
BINARIES=$(patsubst $(SOURCE_DIR)/%.erl, $(BINARY_DIR)/%.beam, $(SOURCES))

all: code

code: $(BINARIES)

$(BINARY_DIR)/%.beam: $(SOURCE_DIR)/%.erl $(BINARY_DIR)
	erlc -o $(BINARY_DIR) $<

$(BINARY_DIR):
	mkdir $@

clean:
	rm -fv $(BINARIES) erl_crash.dump

dist-src: clean
	tar zcvf erlang_couchdb-0.2.3.tgz Makefile src/
