.POSIX:
EMACS = emacs
BATCH = $(EMACS) -batch -Q -L .

compile: httpd.elc httpd-test.elc simple-httpd.elc

test: check
check: httpd-test.elc
	$(BATCH) -l httpd-test.elc -f ert-run-tests-batch

clean:
	rm -f httpd.elc httpd-test.elc simple-httpd.elc

httpd-test.elc: httpd-test.el httpd.elc

.SUFFIXES: .el .elc
.el.elc:
	$(BATCH) -f batch-byte-compile $<
