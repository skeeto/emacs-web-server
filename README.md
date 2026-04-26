# Simple Emacs web server (httpd.el)

[![MELPA](http://melpa.org/packages/httpd-badge.svg)](http://melpa.org/#/httpd)
[![MELPA Stable](http://stable.melpa.org/packages/httpd-badge.svg)](http://stable.melpa.org/#/httpd)

A simple Emacs web server.

This package has been called `simple-httpd.el` in the past but has been renamed
back to `httpd.el`. The package can serve files and directory listings, and
supports custom servlet functions. Client requests are sanitized so this
*should* be safe, but I make no guarantees.

This package is available on [MELPA](https://melpa.org/).

## Usage

Once loaded, there are only two interactive functions to worry about:
`httpd-start` and `httpd-stop`. Files are served from `httpd-root`
(can be changed at any time) on port `httpd-port`. Directory listings
are enabled by default but can be disabled by setting `httpd-listings`
to `nil`.

```cl
(require 'httpd)
(setq httpd-root "/var/www")
(httpd-start)
```

## Servlets

Servlets can be defined with `defservlet`. This one creates at servlet
at `/hello-world` that says hello.

```cl
(defservlet hello-world text/plain (path)
  (insert "hello, " (file-name-nondirectory path)))
```

See the comment header in `httpd.el` for full details.

## Extensions

Packages built on httpd:

 * [skewer-mode](https://github.com/skeeto/skewer-mode)
 * [impatient-mode](https://github.com/netguy204/imp.el)
 * [airplay](https://github.com/gongo/airplay-el)
 * [elfeed-web](https://github.com/skeeto/elfeed)

## Unit tests

The unit tests can (and should usually) be run like so,

    emacs -batch -L . -l httpd-test.el -f ert-run-tests-batch

It does some mocking to avoid using network code during testing.
