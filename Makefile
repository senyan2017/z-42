readme:
	@groff -man -Tascii z.1 | col -bx

test:
	@bash tests.sh

.PHONY: readme test
