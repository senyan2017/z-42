readme:
	@GROFF_NO_SGR=1 groff -man -Tascii z.1 | col -bx

.PHONY: readme
