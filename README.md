# simple-httpd

[![MELPA](http://melpa.org/packages/simple-httpd-badge.svg)](http://melpa.org/#/simple-httpd)
[![MELPA Stable](http://stable.melpa.org/packages/simple-httpd-badge.svg)](http://stable.melpa.org/#/simple-httpd)

A simple Emacs web server.

This used to be `httpd.el` but there are already several of these out
there already of varying usefulness. Since the name change, it's been
stripped down to simply serve files and directory listings. Client
requests are sanitized so this *should* be safe, but I make no
guarantees.

This package is available on [MELPA](https://melpa.org/).

## Usage

Once loaded, there are only two interactive functions to worry about:
`httpd-start` and `httpd-stop`. Files are served from `httpd-root`
(can be changed at any time) on port `httpd-port`. Directory listings
are enabled by default but can be disabled by setting `httpd-listings`
to `nil`.

```emacs-lisp
(require 'simple-httpd)
(setq httpd-root "/var/www")
(httpd-start)
```

## Servlets

Servlets can be defined with `defservlet`. This one creates at servlet
at `/hello-world` that says hello.

```emacs-lisp
(defservlet hello-world text/plain (path)
  (insert "hello, " (file-name-nondirectory path)))
```

Another example at `/greeting/<name>` with optional parameter
`?greeting=<greeting>`.

```emacs-lisp
(defservlet* greeting/:name text/plain ((greeting "hi" greeting-p))
  (insert (format "%s, %s (provided: %s)" greeting name greeting-p)))
```

See the comment header in `simple-httpd.el` for full details.

## Extensions

Packages built on simple-httpd:

 * [skewer-mode](https://github.com/skeeto/skewer-mode)
 * [impatient-mode](https://github.com/netguy204/imp.el)
 * [airplay](https://github.com/gongo/airplay-el)
 * [elfeed-web](https://github.com/skeeto/elfeed)

## Unit tests

The unit tests can be run with `make test`. The tests do some mocking to avoid
using network code during testing.
