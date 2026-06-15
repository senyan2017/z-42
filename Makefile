readme:
	@groff -man -Tascii z.1 | col -bx

test:
	@bash t/test.sh

.PHONY: readme test
