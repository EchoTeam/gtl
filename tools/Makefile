OBJECTS=gtl-analyzer

all: ${OBJECTS}

gtl-analyzer: build
	cp dist/build/gtl-analyzer/gtl-analyzer .

.PHONY: build
build:
	runhaskell Setup.hs configure --user
	runhaskell Setup.hs build

.PHONY: clean
clean:
	runhaskell Setup.hs clean

.PHONY: install
install: build
	runhaskell Setup.hs install
