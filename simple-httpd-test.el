;;; simple-httpd-test.el --- simple-httpd unit tests -*- lexical-binding: t -*-

;;; Commentary:

;; Run standalone with this,
;;   emacs -batch -L . -l simple-httpd-test.el -f ert-run-tests-batch

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'simple-httpd)

(defmacro httpd--flet (funcs &rest body)
  "Like `cl-flet' but with dynamic function scope."
  (declare (indent 1))
  (let* ((names (mapcar #'car funcs))
         (lambdas (mapcar #'cdr funcs))
         (gensyms (cl-loop for name in names
                           collect (make-symbol (symbol-name name)))))
    `(let ,(cl-loop for name in names
                    for gensym in gensyms
                    collect `(,gensym (symbol-function ',name)))
       (unwind-protect
           (progn
             ,@(cl-loop for name in names
                        for lambda in lambdas
                        for body = `(lambda ,@lambda)
                        collect `(setf (symbol-function ',name) ,body))
             ,@body)
         ,@(cl-loop for name in names
                    for gensym in gensyms
                    collect `(setf (symbol-function ',name) ,gensym))))))

(ert-deftest httpd-clean-path-test ()
  "Ensure that paths are sanitized properly."
  (should (equal (httpd-clean-path "/") "./"))
  (should (equal (httpd-clean-path "../") "./"))
  (should (equal (httpd-clean-path "/../../foo/../..") "./foo"))
  (should (equal (httpd-clean-path "/tmp/../root/foo") "./tmp/root/foo"))
  (should (equal (httpd-clean-path "~") "./~"))
  (should (equal (httpd-clean-path "/~/.gnupg") "./~/.gnupg")))

(ert-deftest httpd-mime-test ()
  "Test MIME type fetching."
  (should (equal (httpd-get-mime "unknown") "application/octet-stream"))
  (should (equal (httpd-get-mime nil) "application/octet-stream")))

(ert-deftest httpd-parse-test ()
  "Test HTTP header parsing."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert "GET /f%20b HTTP/1.1\r\n"
            "Host: localhost:8080\r\n"
            "DNT: 1, 2\r\n\r\n")
    (should (equal (httpd-parse) '(("GET" "/f%20b" "HTTP/1.1")
                                   ("Host" "localhost:8080")
                                   ("Dnt" "1, 2"))))))

(ert-deftest httpd-parse-uri-test ()
  "Test URI parsing."
  (should (equal (httpd-parse-uri "foo?k=v#fragment") '("foo" (("k" "v")) "fragment")))
  (should (equal (httpd-parse-uri "foo#fragment?k=v") '("foo" nil "fragment?k=v")))
  (should (equal (httpd-parse-uri "/foo/bar%20baz.html?q=test%26case&v=10#page10")
                 '("/foo/bar%20baz.html" (("q" "test&case") ("v" "10")) "page10"))))

(defun httpd-send-header-test-helper (request &rest args)
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((out (current-buffer)))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (httpd--flet ((process-get (_proc _prop) request)
                      (process-put (_proc _prop _val))
                      (process-send-eof (_proc))
                      (process-send-region (_proc start end)
                        (let ((send-buffer (current-buffer)))
                          (with-current-buffer out
                            (insert-buffer-substring send-buffer start end))))
                      (process-send-string (_proc str)
                        (with-current-buffer out
                          (insert str))))
          (insert "content")
          (apply #'httpd-send-header nil args))))
    (httpd-parse)))

(ert-deftest httpd-send-header-test ()
  "Test server header output."
  (let ((h (httpd-send-header-test-helper '(("GET" "/" "HTTP/1.1"))
                                          "text/html" 404 :Foo "bar")))
    (should (equal (car h) '("HTTP/1.1" "404" "Not Found")))
    (should (equal (cdr (assoc "Content-Type" h)) '("text/html; charset=utf-8")))
    (should (equal (cdr (assoc "Content-Length" h)) '("7")))
    (should (equal (cdr (assoc "Connection" h)) '("keep-alive")))
    (should (equal (cdr (assoc "Server" h)) (list httpd-server-name)))
    (should (equal (cdr (assoc "Foo" h)) '("bar"))))
  (let ((h (httpd-send-header-test-helper '(("GET" "/" "HTTP/1.1")
                                            ("Connection" "close"))
                                          "text/plain" 403)))
    (should (equal (car h) '("HTTP/1.1" "403" "Forbidden")))
    (should (equal (cdr (assoc "Content-Type" h)) '("text/plain; charset=utf-8")))
    (should (equal (cdr (assoc "Content-Length" h)) '("7")))
    (should (equal (cdr (assoc "Connection" h)) '("close")))
    (should (equal (cdr (assoc "Server" h)) (list httpd-server-name))))
  (let ((h (httpd-send-header-test-helper '(("GET" "/" "HTTP/1.0"))
                                          "text/plain" 401)))
    (should (equal (car h) '("HTTP/1.0" "401" "Unauthorized")))
    (should (equal (cdr (assoc "Content-Type" h)) '("text/plain; charset=utf-8")))
    (should (equal (cdr (assoc "Content-Length" h)) '("7")))
    (should (equal (cdr (assoc "Connection" h)) '("close")))
    (should (equal (cdr (assoc "Server" h)) (list httpd-server-name)))))

(ert-deftest httpd-get-servlet-test ()
  "Test servlet dispatch."
  (httpd--flet ((httpd/foo/bar () t))
    (let ((httpd-servlets t))
      (should (eq (httpd-get-servlet "/foo/bar")     'httpd/foo/bar))
      (should (eq (httpd-get-servlet "/foo/bar/baz") 'httpd/foo/bar))
      (should (eq (httpd-get-servlet "/undefined")   'httpd/)))))

(ert-deftest httpd-unhex-test ()
  "Test URL decoding."
  (should (equal (httpd-unhex "I+%2Bam%2B+foo.") "I +am+ foo."))
  (should (equal (httpd-unhex "foo%0D%0Abar") "foo\nbar"))
  (should (equal (httpd-unhex "na%C3%AFve") "naïve"))
  (should (eq (httpd-unhex nil) nil)))

(ert-deftest httpd-parse-args-test ()
  "Test argument parsing."
  (should (equal (httpd-parse-args "na=foo&v=1") '(("na" "foo") ("v" "1"))))
  (should (equal (httpd-parse-args "foo=bar=baz") '(("foo" "bar" "baz"))))
  (should (equal (httpd-parse-args "foo&bar") '(("foo") ("bar"))))
  (should (equal (httpd-parse-args "foo&&bar&&") '(("foo") ("bar"))))
  (should (equal (httpd-parse-args "") ())))

(ert-deftest httpd-parse-endpoint ()
  "Test endpoint parsing for `httpd-servlet*'."
  (should (equal (httpd-parse-endpoint 'example/foos/:n/:d)
                 '(example/foos ((n . 2) (d . 3))))))

(ert-deftest httpd-escape-html-test ()
  "Test URL decoding."
  (let ((tests '(("hello world" .
                  "hello world")
                 ("a <b>bold</b> request" .
                  "a &lt;b&gt;bold&lt;/b&gt; request")
                 ("alpha & beta" .
                  "alpha &amp; beta")
                 ("don't" .
                  "don&apos;t")
                 ("\"quoted\"" .
                  "&quot;quoted&quot;")
                 ("&&&" .
                  "&amp;&amp;&amp;"))))
    (cl-loop for (in . out) in tests
             do (should
                 (equal (with-temp-buffer
                          (insert in)
                          (httpd-escape-html-buffer)
                          (buffer-string))
                        out)))
    (cl-loop for (in . out) in tests
             do (should (equal (httpd-escape-html in) out)))))

;;; simple-httpd-test.el ends here
