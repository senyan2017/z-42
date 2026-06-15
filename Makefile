readme:
	@groff -man -Tascii z.1 | col -bx

test:
	@bash tests/test_import_export.sh

.PHONY: readme test
