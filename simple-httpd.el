;;; simple-httpd.el --- Pure Elisp HTTP server -*- lexical-binding: t -*-

;; This is free and unencumbered software released into the public domain.

;; Author: Christopher Wellons <wellons@nullprogram.com>
;; Maintainers: Philip Kaludercic <philipk@posteo.net>,
;;              Daniel Mendler <mail@daniel-mendler.de>
;; URL: https://github.com/skeeto/emacs-http-server
;; Version: 1.5.1
;; Package-Requires: ((emacs "26.1") (compat "30"))
;; Keywords: network, comm

;;; Commentary:

;; Use `httpd-start' to start the web server.  Files are served from
;; `httpd-root' on port `httpd-port' using `httpd-ip-family' at host
;; `httpd-host'.  While the root can be changed at any time, the server
;; needs to be restarted in order for a port change to take effect.

;; Everything is performed by servlets, including serving
;; files.  Servlets are enabled by setting `httpd-servlets' to true
;; (default).  Servlets are four-parameter functions that begin with
;; "httpd/" where the trailing component specifies the initial path on
;; the server.  For example, the function `httpd/hello-world' will be
;; called for the request "/hello-world" and "/hello-world/foo".

;; The default servlet `httpd/' is the one that serves files from
;; `httpd-root' and can be turned off through redefinition or setting
;; `httpd-serve-files' to nil.  It is used even when `httpd-servlets'
;; is nil.

;; The four parameters for a servlet are process, URI path, GET/POST
;; arguments (alist), and the full request object (header
;; alist).  These are ordered by general importance so that some can be
;; ignored.  Two macros are provided to help with writing servlets.

;;  * `with-httpd-buffer' -- Creates a temporary buffer that is
;;    automatically served to the client at the end of the body.
;;    Additionally, `standard-output' is set to this output
;;    buffer.  For example, this servlet says hello,

;;     (defun httpd/hello-world (proc path &rest args)
;;       (with-httpd-buffer proc "text/plain"
;;         (insert "hello, " (file-name-nondirectory path))))

;; This servlet be viewed at http://localhost:8080/hello-world/Emacs

;; * `defservlet' -- Similar to the above macro but totally hides the
;;   process object from the servlet itself.  The above servlet can be
;;   re-written identically like so,

;;     (defservlet hello-world text/plain (path)
;;       (insert "hello, " (file-name-nondirectory path)))

;; Note that `defservlet' automatically sets `httpd-current-proc'.  See
;; below.

;; The "function parameters" part can be left empty or contain up to
;; three parameters corresponding to the final three servlet
;; parameters.  For example, a servlet that shows *scratch* and doesn't
;; need parameters,

;;     (defservlet scratch text/plain ()
;;       (insert-buffer-substring (get-buffer-create "*scratch*")))

;; A higher level macro `defservlet*' wraps this lower-level
;; `defservlet' macro, automatically binding variables to components
;; of the request.  For example, this binds parts of the request path
;; and one query parameter.  Request components not provided by the
;; client are bound to nil.

;;     (defservlet* packages/:package/:version text/plain (verbose)
;;       (insert (format "%s\n%s\n" package version))
;;       (princ (get-description package version))
;;       (when verbose
;;         (insert (format "%S" (get-dependencies package version)))))

;; It would be accessed like so,

;;     http://example.com/packages/foobar/1.0?verbose=1

;; Some support functions are available for servlets for more
;; customized responses.

;;   * `httpd-send-file'   -- serve a file with proper caching
;;   * `httpd-redirect'    -- redirect the browser to another url
;;   * `httpd-send-header' -- send custom headers
;;   * `httpd-error'       -- report an error to the client
;;   * `httpd-log'         -- log an object to *httpd*

;; Some of these functions require a process object, which isn't
;; passed to `defservlet' servlets.  Use t in place of the process
;; argument to use `httpd-current-proc' (like `standard-output').

;; If you just need to serve static from some location under some
;; route on the server, use `httpd-def-file-servlet'.  It expands into
;; a `defservlet' that serves files.

;;; History:

;; Version 1.5.1: improvements
;;   * Add `httpd-running-p'
;;   * Properly handle "Connection: close" and HTTP/1.0
;; Version 1.5.0: improvements
;;   * Drastically improved performance for large requests
;;   * More HTTP status codes
;; Version 1.4.6: fixes
;;   * Added httpd-serve-directory
;;   * Fix some encoding issues
;; Version 1.4.5: fixes
;;   * Update to cl-lib from cl
;; Version 1.4.4: features
;;   * Common Lisp &key-like defservlet* argument support
;;   * Fix up some defservlet* usage warnings.
;; Version 1.4.3: features
;;   * Add `httpd-discard-buffer'
;;   * Add `httpd-def-file-servlet'
;;   * Be more careful about not sending extra headers
;; Version 1.4.2: features, fixes
;;   * `defservlet*' macro
;; Version 1.4.1: small bug fixes, one feature
;;   * All mime-type parameters now accept string designators
;;   * Documentation update
;; Version 1.4.0: features, API change, and fixes
;;   * Removed httpd-send-buffer; httpd-send-header now does this implicitly
;;   * httpd-send-header now accepts keywords instead
;;   * Fix httpd-clean-path in Windows
;;   * Fix a content-length bug
;;   * defservlet fontification
;; Version 1.3.1: features and fixes
;;   * Set `standard-output' in `with-httpd-buffer'
;; Version 1.3.0: security fix
;;   * Fix path expansion security issue
;;   * Fix coding system (don't default)
;; Version 1.2.4: fixes
;;   * Handle large POSTs
;;   * Fix date strings

;;; Code:

(eval-when-compile (require 'subr-x))
(require 'cl-lib)
(require 'pp)
(require 'url-util)
(require 'compat)

(defgroup simple-httpd nil
  "A simple web server."
  :group 'comm)

(defcustom httpd-ip-family 'ipv4
  "Web server IP family used by `make-network-process'."
  :type 'symbol)

(defcustom httpd-host nil
  "Web server host name used by `make-network-process'."
  :type '(choice (const nil) (const local) string))

(defcustom httpd-port 8080
  "Web server port."
  :type 'integer)

(defcustom httpd-root "~/public_html"
  "Web server file root."
  :type 'directory)

(defcustom httpd-serve-files t
  "Enable serving files from `httpd-root'."
  :type 'boolean)

(defcustom httpd-listings t
  "If true, serve directory listings."
  :type 'boolean)

(defcustom httpd-servlets t
  "Enable servlets."
  :type 'boolean)

(defcustom httpd-show-backtrace-when-error nil
  "If true, show backtrace on error page."
  :type 'boolean)

(defcustom httpd-start-hook nil
  "Hook to run when the server has started."
  :type 'hook)

(defcustom httpd-stop-hook nil
  "Hook to run when the server has stopped."
  :type 'hook)

(defvar httpd-server-name (format "simple-httpd (Emacs %s)" emacs-version)
  "String to use in the Server header.")

(defvar httpd-mime-types
  '(("png"  . "image/png")
    ("gif"  . "image/gif")
    ("jpg"  . "image/jpeg")
    ("jpeg" . "image/jpeg")
    ("tif"  . "image/tif")
    ("tiff" . "image/tiff")
    ("webp" . "image/webp")
    ("ico"  . "image/x-icon")
    ("svg"  . "image/svg+xml")
    ("css"  . "text/css; charset=utf-8")
    ("htm"  . "text/html; charset=utf-8")
    ("html" . "text/html; charset=utf-8")
    ("xml"  . "text/xml; charset=utf-8")
    ("rss"  . "text/xml; charset=utf-8")
    ("atom" . "text/xml; charset=utf-8")
    ("txt"  . "text/plain; charset=utf-8")
    ("el"   . "text/plain; charset=utf-8")
    ("js"   . "text/javascript; charset=utf-8")
    ("md"   . "text/markdown; charset=utf-8")
    ("org"  . "text/org; charset=utf-8")
    ("gz"   . "application/octet-stream")
    ("ps"   . "application/postscript")
    ("eps"  . "application/postscript")
    ("pdf"  . "application/pdf")
    ("tar"  . "application/x-tar")
    ("zip"  . "application/zip")
    ("wasm" . "application/wasm")
    ("mp3"  . "audio/mpeg")
    ("wav"  . "audio/x-wav")
    ("flac" . "audio/flac")
    ("spx"  . "audio/ogg")
    ("oga"  . "audio/ogg")
    ("ogg"  . "audio/ogg")
    ("ogv"  . "video/ogg")
    ("mp4"  . "video/mp4")
    ("mkv"  . "video/x-matroska")
    ("webm" . "video/webm"))
  "MIME types for headers.")

(defvar httpd-indexes
  '("index.html"
    "index.htm"
    "index.xml")
  "File served by default when accessing a directory.")

(defvar httpd-status-codes
  '((100 . "Continue")
    (101 . "Switching Protocols")
    (102 . "Processing")
    (200 . "OK")
    (201 . "Created")
    (202 . "Accepted")
    (203 . "Non-authoritative Information")
    (204 . "No Content")
    (205 . "Reset Content")
    (206 . "Partial Content")
    (207 . "Multi-Status")
    (208 . "Already Reported")
    (226 . "IM Used")
    (300 . "Multiple Choices")
    (301 . "Moved Permanently")
    (302 . "Found")
    (303 . "See Other")
    (304 . "Not Modified")
    (305 . "Use Proxy")
    (307 . "Temporary Redirect")
    (308 . "Permanent Redirect")
    (400 . "Bad Request")
    (401 . "Unauthorized")
    (402 . "Payment Required")
    (403 . "Forbidden")
    (404 . "Not Found")
    (405 . "Method Not Allowed")
    (406 . "Not Acceptable")
    (407 . "Proxy Authentication Required")
    (408 . "Request Timeout")
    (409 . "Conflict")
    (410 . "Gone")
    (411 . "Length Required")
    (412 . "Precondition Failed")
    (413 . "Payload Too Large")
    (414 . "Request-URI Too Long")
    (415 . "Unsupported Media Type")
    (416 . "Requested Range Not Satisfiable")
    (417 . "Expectation Failed")
    (418 . "I'm a teapot")
    (421 . "Misdirected Request")
    (422 . "Unprocessable Entity")
    (423 . "Locked")
    (424 . "Failed Dependency")
    (426 . "Upgrade Required")
    (428 . "Precondition Required")
    (429 . "Too Many Requests")
    (431 . "Request Header Fields Too Large")
    (444 . "Connection Closed Without Response")
    (451 . "Unavailable For Legal Reasons")
    (499 . "Client Closed Request")
    (500 . "Internal Server Error")
    (501 . "Not Implemented")
    (502 . "Bad Gateway")
    (503 . "Service Unavailable")
    (504 . "Gateway Timeout")
    (505 . "HTTP Version Not Supported")
    (506 . "Variant Also Negotiates")
    (507 . "Insufficient Storage")
    (508 . "Loop Detected")
    (510 . "Not Extended")
    (511 . "Network Authentication Required")
    (599 . "Network Connect Timeout Error"))
  "HTTP status codes.")

(defvar httpd-html
  '((403 . "<!DOCTYPE html>
<html><head>
<title>403 Forbidden</title>
</head><body>
<h1>Forbidden</h1>
<p>The requested URL is forbidden.</p>
<pre>%s</pre>
</body></html>")
    (404 . "<!DOCTYPE html>
<html><head>
<title>404 Not Found</title>
</head><body>
<h1>Not Found</h1>
<p>The requested URL was not found on this server.</p>
<pre>%s</pre>
</body></html>")
    (500 . "<!DOCTYPE html>
<html><head>
<title>500 Internal Error</title>
</head><body>
<h1>500 Internal Error</h1>
<p>Internal error when handling this request.</p>
<pre>%s</pre>
</body></html>"))
  "HTML for various errors.")

(defvar httpd--server nil
  "Server process.")

(defvar httpd--clients nil
  "Client processes.")

;; User interface

;;;###autoload
(defun httpd-start ()
  "Start the web server process.
If the server is already running, this will restart the server.  There
is only one server instance per Emacs instance."
  (interactive)
  (httpd-stop)
  (httpd-log `(start ,(current-time-string)))
  (setq httpd--server
        (make-network-process
         :name     "httpd"
         :service  httpd-port
         :server   t
         :host     httpd-host
         :family   httpd-ip-family
         :filter   #'httpd--filter
         :coding   'binary
         :log      #'httpd--log))
  (run-hooks 'httpd-start-hook))

;;;###autoload
(defun httpd-stop ()
  "Stop the web server if it is currently running, otherwise do nothing."
  (interactive)
  (when (httpd-running-p)
    (mapc #'delete-process httpd--clients)
    (delete-process httpd--server)
    (setq httpd--server nil
          httpd--clients nil)
    (httpd-log `(stop ,(current-time-string)))
    (run-hooks 'httpd-stop-hook)))

;;;###autoload
(defun httpd-running-p ()
  "Return non-nil if the simple-httpd server is running."
  (process-live-p httpd--server))

;;;###autoload
(defun httpd-serve-directory (directory)
  "Start the web server with given DIRECTORY as `httpd-root'."
  (interactive "DServe directory: \n")
  (setf httpd-root directory)
  (httpd-start)
  (message "Started simple-httpd on %s:%d, serving: %s"
           (cl-case httpd-host
             ((nil local) "localhost")
             (otherwise httpd-host))
           httpd-port directory))

(defun httpd-batch-start ()
  "Never returns, holding the server open indefinitely for batch mode.
Logs are redirected to stdout.  To use, invoke Emacs like this:
  \"emacs -Q -batch -l simple-httpd.elc -f httpd-batch-start\""
  (if (not noninteractive)
      (error "Only use `httpd-batch-start' in batch mode!")
    (httpd-start)
    (defalias 'httpd-log 'pp)
    (while t (sleep-for 60))))

;; Utility

(defun httpd-date-string (&optional date)
  "Return DATE as HTTP date string (RFC 1123)."
  (format-time-string "%a, %e %b %Y %T GMT" date t))

(defun httpd-etag (file)
  "Compute the ETag for FILE."
  (concat "\"" (substring (sha1 (prin1-to-string (file-attributes file))) -16)
          "\""))

(defun httpd--stringify (designator)
  "Turn a string DESIGNATOR into a string."
  (let ((string (format "%s" designator)))
    (if (keywordp designator)
        (substring string 1)
      string)))

;; Networking code

(defun httpd--connection-close-p (request)
  "Return non-nil if the REQUEST has \"connection: close\"."
  (or (equal '("close") (cdr (assoc "Connection" request)))
      (equal '("HTTP/1.0") (cddr (assoc "GET" request)))))

(defun httpd--filter (proc chunk)
  "Process called each time client makes a request.
PROC is the client process and CHUNK is part of the request as string."
  (with-current-buffer (process-get proc :request-buffer)
    (goto-char (point-max))
    (insert chunk)
    (let ((request (process-get proc :request)))
      (unless request
        (when (setf request (httpd-parse))
          (delete-region (point-min) (point))
          (process-put proc :request request)))
      (when request
        (let ((content-length (cadr (assoc "Content-Length" request))))
          (when (or (null content-length)
                    (= (buffer-size) (string-to-number content-length)))
            (let* ((content (buffer-string))
                   (uri (cadar request))
                   (parsed-uri (httpd-parse-uri (concat uri)))
                   (uri-path (httpd-unhex (nth 0 parsed-uri)))
                   (uri-query (append (nth 1 parsed-uri)
                                      (httpd-parse-args content)))
                   (servlet (httpd-get-servlet uri-path)))
              (erase-buffer)
              (process-put proc :request nil)
              (setf request (nreverse (cons (list "Content" content)
                                            (nreverse request))))
              (httpd-log `(request (date ,(httpd-date-string))
                                   (address ,(car (process-contact proc)))
                                   (get ,uri-path)
                                   ,(cons 'headers request)))
              (if (null servlet)
                  (httpd--error-safe proc 404)
                (condition-case error-case
                    (funcall servlet proc uri-path uri-query request)
                  (error (httpd--error-safe proc 500 error-case))))
              (when (httpd--connection-close-p request)
                (process-send-eof proc)))))))))

(defun httpd--log (_server proc _message)
  "Runs each time a new client PROC connects to the server."
  (push proc httpd--clients)
  (with-current-buffer (generate-new-buffer " *httpd-client*")
    (process-put proc :request-buffer (current-buffer)))
  (set-process-sentinel proc #'httpd--sentinel)
  (httpd-log (list 'connection (car (process-contact proc)))))

(defun httpd--sentinel (proc message)
  "Runs when a client PROC closes the connection.
MESSAGE describes the state change."
  (unless (string-prefix-p "open " message)
    (cl-callf2 delq proc httpd--clients)
    (let ((buffer (process-get proc :request-buffer)))
      (when buffer
        (kill-buffer buffer)))))

;; Logging

(defun httpd-log (item)
  "Pretty print ITEM to the log."
  (with-current-buffer (get-buffer-create "*httpd*")
    (setf buffer-read-only nil)
    (let ((follow (= (point) (point-max))))
      (save-excursion
        (goto-char (point-max))
        (pp item (current-buffer)))
      (if follow (goto-char (point-max))))
    (setf truncate-lines t
          buffer-read-only t)
    (set-buffer-modified-p nil)))

;; Servlets

(defvar httpd-current-proc nil
  "The process object currently in use.")

(defvar-local httpd--header-sent nil
  "Buffer-local variable indicating if the header has been sent.")

(defun httpd-resolve-proc (proc)
  "Return the correct process to use.
Return `httpd-current-proc' if PROC is t."
  (if (eq t proc) httpd-current-proc proc))

(defmacro with-httpd-buffer (proc mime &rest body)
  "Create temporary buffer and serve it to the client.
Create a temporary buffer, set it as the current buffer, and, at the end
of body, automatically serve it to an HTTP client with an HTTP header
indicating the specified MIME type.  Additionally, `standard-output' is
set to this output buffer and `httpd-current-proc' is set to PROC."
  (declare (indent defun))
  (cl-once-only (proc)
    `(with-temp-buffer
       (setf major-mode 'httpd-buffer)
       (let ((standard-output (current-buffer))
             (httpd-current-proc ,proc))
         ,@body)
       (httpd-send-header ,proc ,mime 200))))

(defun httpd-discard-buffer ()
  "Don't respond using current server buffer (`with-httpd-buffer').
Returns a process for future response."
  (when (eq major-mode 'httpd-buffer) (setf httpd--header-sent t))
  httpd-current-proc)

(defmacro defservlet (name mime path-query-request &rest body)
  "Defines a simple httpd servlet.

NAME is the servlet name as symbol.
MIME the mime-type as symbol.
PATH-QUERY-REQUEST is the argument list.
BODY is the function body.

The servlet runs in a temporary buffer which is automatically served to
the client along with a header.

A servlet that serves the contents of *scratch*,

    (defservlet scratch text/plain ()
      (insert-buffer-substring (get-buffer-create \"*scratch*\")))

A servlet that says hello,

    (defservlet hello-world text/plain (path)
      (insert \"hello, \" (file-name-nondirectory path))))"
  (declare (indent defun))
  (let ((proc-sym (make-symbol "proc"))
        (fname (intern (concat "httpd/" (symbol-name name)))))
    `(defun ,fname (,proc-sym ,@path-query-request &rest ,(gensym))
       (with-httpd-buffer ,proc-sym ,(httpd--stringify mime)
         ,@body))))

(defun httpd-parse-endpoint (symbol)
  "Parse an endpoint template SYMBOL for use with `defservlet*'."
  (cl-loop for item in (split-string (symbol-name symbol) "/")
           for n upfrom 0
           when (and (> (length item) 0) (eql (aref item 0) ?:))
           collect (cons (intern (substring item 1)) n) into vars
           else collect item into path
           finally
           (cl-return
            (cl-values (intern (string-join path "/")) vars))))

(defvar httpd-path nil
  "Anaphoric variable for `defservlet*'.")

(defvar httpd-query nil
  "Anaphoric variable for `defservlet*'.")

(defvar httpd-request nil
  "Anaphoric variable for `defservlet*'.")

(defvar httpd-split-path nil
  "Anaphoric variable for `defservlet*'.")

(defmacro defservlet* (endpoint mime args &rest body)
  "Like `defservlet', but automatically bind variables/arguments to the request.

ENDPOINT is the path as symbol.
MIME the mime-type as symbol.
ARGS is the argument list.
BODY is the function body.

Trailing components of the ENDPOINT can be bound by prefixing these
components with a colon, acting like a template.

    (defservlet* packages/:package/:version text/plain (verbose)
      (insert (format \"%s\\n%s\\n\" package version))
      (princ (get-description package version))
      (when verbose
        (insert (format \"%S\" (get-dependencies package version)))))

When accessed from this URL,

    http://example.com/packages/foobar/1.0?verbose=1

the variables package, version, and verbose will be bound to the
associated components of the URL.  Components not provided are
bound to nil.  The query arguments can use the Common Lisp &key
form (variable default provided-p).

    (defservlet* greeting/:name text/plain ((greeting \"hi\" greeting-p))
      (princ (format \"%s, %s (provided: %s)\" greeting name greeting-p)))

The original path, query, and request can be accessed by the
anaphoric special variables `httpd-path', `httpd-query', and
`httpd-request'."
  (declare (indent defun))
  (cl-with-gensyms (path-lexical query-lexical request-lexical)
    (cl-multiple-value-bind (path vars) (httpd-parse-endpoint endpoint)
      `(defservlet ,path ,mime (,path-lexical ,query-lexical ,request-lexical)
         (let ((httpd-path ,path-lexical)
               (httpd-query ,query-lexical)
               (httpd-request ,request-lexical)
               (httpd-split-path (split-string
                                  (substring ,path-lexical 1) "/")))
           (let ,(cl-loop for (var . pos) in vars
                          for extract =
                          `(httpd-unhex (nth ,pos httpd-split-path))
                          collect (list var extract))
             (let ,(cl-loop for arg in args
                            for has-default = (listp arg)
                            for has-default-p = (and has-default
                                                     (= 3 (length arg)))
                            for arg-name = (symbol-name
                                            (if has-default (car arg) arg))
                            when has-default collect
                            (list (car arg)
                                  `(let ((value (assoc ,arg-name httpd-query)))
                                     (if value
                                         (cadr value)
                                       ,(cadr arg))))
                            else collect
                            (list arg `(cadr
                                        (assoc ,arg-name httpd-query)))
                            when has-default-p collect
                            (list (caddr arg)
                                  `(not (null (assoc ,arg-name httpd-query)))))
               ,@body)))))))

(font-lock-add-keywords
 'emacs-lisp-mode
 '(("(\\<\\(defservlet\\*?\\)\\> +\\([^ ()]+\\) +\\([^ ()]+\\)"
    (1 'font-lock-keyword-face)
    (2 'font-lock-function-name-face)
    (3 'font-lock-type-face))))

(defmacro httpd-def-file-servlet (name root)
  "Defines a servlet that serves files from ROOT under the route NAME.

    (httpd-def-file-servlet my/www \"/var/www/\")

Automatically handles redirects and uses `httpd-serve-root' to
actually serve up files."
  (let* ((short-root (directory-file-name (symbol-name name)))
         (path-root (concat short-root "/"))
         (chop (length path-root)))
    `(defservlet ,name nil (uri-path query request)
       (setf httpd--header-sent t) ; Don't actually use this temp buffer
       (if (= (length uri-path) ,chop)
           (httpd-redirect t ,path-root)
         (let ((path (substring uri-path ,chop)))
           (httpd-serve-root t ,root path request))))))

;; Request parsing

(defun httpd--normalize-header (header)
  "Destructively capitalize the components of HEADER."
  (mapconcat #'capitalize (split-string header "-") "-"))

(defun httpd-parse ()
  "Parse HTTP header in current buffer into association list.
Leaves the point at the start of the request content.  Returns nil
if it failed to parse a complete HTTP header."
  (goto-char (point-min))
  (when (looking-at "\\([^ ]+\\) +\\([^ ]+\\) +\\([^\r]+\\)\r\n")
    (let ((method (match-string 1))
          (path (decode-coding-string (match-string 2) 'iso-8859-1))
          (version (match-string 3))
          (headers ()))
      (goto-char (match-end 0))
      (while (looking-at "\\([-!#-'*+.0-9A-Z^_`a-z|~]+\\): *\\([^\r]+\\)\r\n")
        (goto-char (match-end 0))
        (let ((name (match-string 1))
              (value (match-string 2)))
          (push (list (httpd--normalize-header name)
                      (decode-coding-string value 'iso-8859-1)) headers)))
      (when (looking-at "\r\n")
        (goto-char (match-end 0))
        (cons (list method path version) (nreverse headers))))))

(defun httpd-unhex (str)
  "Fully decode the URL encoding in STR (including +'s)."
  (when str
    (decode-coding-string
     (url-unhex-string (string-replace "+" " " str) t)
     'utf-8)))

(defun httpd-parse-args (argstr)
  "Parse ARGSTR containing URL encoded arguments."
  (unless (zerop (length argstr))
    (mapcar (lambda (str)
              (mapcar #'httpd-unhex (split-string str "=")))
            (split-string argstr "&"))))

(defun httpd-parse-uri (uri)
  "Split a URI into its components.
The first element of the return value is the script path, the
second element is an alist of variable/value pairs, and the third
element is the fragment."
  (let ((p1 (string-search "?" uri))
        (p2 (string-search "#" uri))
        retval)
    (push (if p2 (httpd-unhex (substring uri (1+ p2)))) retval)
    (push (if p1 (httpd-parse-args (substring uri (1+ p1) p2))) retval)
    (push (substring uri 0 (or p1 p2)) retval)))

(defun httpd-escape-html-buffer ()
  "Escape current buffer contents to be safe for inserting into HTML."
  (goto-char (point-min))
  (while (re-search-forward "[<>&]" nil t)
    (replace-match
     (cl-case (aref (match-string 0) 0)
       (?< "&lt;")
       (?> "&gt;")
       (?& "&amp;")))))

(defun httpd-escape-html (string)
  "Escape STRING so that it's safe to insert into an HTML document."
  (with-temp-buffer
    (insert string)
    (httpd-escape-html-buffer)
    (buffer-string)))

;; Path handling

(defun httpd-status (path)
  "Determine status code for PATH."
  (cond
   ((not (file-exists-p path))   404)
   ((not (file-readable-p path)) 403)
   ((and (file-directory-p path) (not httpd-listings)) 403)
   (200)))

(defun httpd-clean-path (path)
  "Clean dangerous .. from PATH and remove the leading slash."
  (let* ((sep (if (member system-type '(windows-nt ms-dos)) "[/\\]" "/"))
         (split (delete ".." (split-string path sep)))
         (unsplit (string-join (delete "" split) "/")))
    (concat "./" unsplit)))

(defun httpd-gen-path (path &optional root)
  "Generate secure path in ROOT from request PATH.
ROOT defaults to `httpd-root'."
  (let ((clean (expand-file-name (httpd-clean-path path) (or root httpd-root))))
    (if (file-directory-p clean)
        (let* ((dir (file-name-as-directory clean))
               (indexes (cl-mapcar (apply-partially #'concat dir) httpd-indexes))
               (existing (cl-remove-if-not #'file-exists-p indexes)))
          (or (car existing) dir))
      clean)))

(defun httpd-get-servlet (uri-path)
  "Determine the servlet to be executed for URI-PATH."
  (if (not httpd-servlets)
      'httpd/
    (cl-labels ((cat (x)
                  (concat "httpd/" (string-join (reverse x) "/"))))
      (let ((parts (cdr (split-string (directory-file-name uri-path) "/"))))
        (or
         (cl-find-if #'fboundp (mapcar #'intern-soft
                                      (cl-maplist #'cat (reverse parts))))
         'httpd/)))))

(defun httpd-serve-root (proc root uri-path &optional request)
  "Securely serve a file from ROOT.
PROC is the client process, URI-PATH the request path and REQUEST the
request header as alist."
  (let* ((path (httpd-gen-path uri-path root))
         (status (httpd-status path)))
    (cond
     ((not (= status 200))    (httpd-error          proc status))
     ((file-directory-p path) (httpd-send-directory proc path uri-path))
     (t                       (httpd-send-file      proc path request)))))

(defun httpd/ (proc uri-path _query request)
  "Default root servlet which serves files when `httpd-serve-files' is t.
PROC is the client process, URI-PATH the request path and REQUEST the
request header as alist."
  (if (and httpd-serve-files httpd-root)
      (httpd-serve-root proc httpd-root uri-path request)
    (httpd-error proc 403)))

(defun httpd-get-mime (ext)
  "Fetch MIME type given the file extension EXT."
  (or (and ext (cdr (assoc (downcase ext) httpd-mime-types)))
      "application/octet-stream"))

;; Data sending functions

(defun httpd-send-header (proc mime status &rest header-keys)
  "Send an HTTP header followed by the current buffer.
MIME is the mime type and STATUS the HTTP status code.  If PROC is t use
the `httpd-current-proc' as the process.

Extra headers can be sent by supplying them like keywords, i.e.

 (httpd-send-header t \"text/plain\" 200 :X-Powered-By \"simple-httpd\")"
  (unless httpd--header-sent
    (setf httpd--header-sent t)
    (let ((status-str (cdr (assq status httpd-status-codes)))
          (headers `(("Server" . ,httpd-server-name)
                     ("Date" . ,(httpd-date-string))
                     ("Connection" . "keep-alive")
                     ("Content-Type" . ,(httpd--stringify mime))
                     ("Content-Length" . ,(httpd--buffer-size)))))
      (with-temp-buffer
        (insert (format "HTTP/1.1 %d %s\r\n" status status-str))
        (cl-loop for (header value) on header-keys by #'cddr
                 for header-name = (substring (symbol-name header) 1)
                 for value-name = (format "%s" value)
                 collect (cons header-name value-name) into extras
                 finally (setf headers (nconc headers extras)))
        (dolist (header headers)
          (insert (format "%s: %s\r\n" (car header) (cdr header))))
        (insert "\r\n")
        (process-send-region (httpd-resolve-proc proc)
                             (point-min) (point-max)))
      (process-send-region (httpd-resolve-proc proc)
                           (point-min) (point-max)))))

(defun httpd-redirect (proc path &optional code)
  "Redirect the client to PATH (default 301).
If PROC is t use the `httpd-current-proc' as the process."
  (httpd-log (list 'redirect path))
  (httpd-discard-buffer)
  (with-temp-buffer
    (httpd-send-header proc "text/plain" (or code 301) :Location path)))

(defun httpd-send-file (proc path &optional req)
  "Serve file at PATH to the given client PROC.
REQ is the request.  If PROC is t use the `httpd-current-proc' as the
process."
  (httpd-discard-buffer)
  (let ((req-etag (cadr (assoc "If-None-Match" req)))
        (etag (httpd-etag path))
        (mtime (httpd-date-string (nth 4 (file-attributes path)))))
    (if (equal req-etag etag)
        (with-temp-buffer
          (httpd-log `(file ,path not-modified))
          (httpd-send-header proc "text/plain" 304))
      (httpd-log `(file ,path))
      (with-temp-buffer
        (set-buffer-multibyte nil)
        (insert-file-contents-literally path)
        (httpd-send-header proc (httpd-get-mime (file-name-extension path))
                           200 :Last-Modified mtime :ETag etag)))))

(defun httpd-send-directory (proc path uri-path)
  "Serve a file listing to the client.
PROC is the client process, PATH the directory PATH, URI-PATH the
request path and REQUEST the request header as alist.  If PROC is t use
the `httpd-current-proc' as the process."
  (httpd-discard-buffer)
  (let ((title (concat "Directory listing for "
                       (url-insert-entities-in-string uri-path))))
    (if (string-suffix-p "/" uri-path)
        (with-temp-buffer
          (httpd-log `(directory ,path))
          (insert "<!DOCTYPE html>\n")
          (insert "<html>\n<head><title>" title "</title></head>\n")
          (insert "<body>\n<h2>" title "</h2>\n<hr/>\n<ul>")
          (dolist (file (directory-files path))
            (unless (eq ?. (aref file 0))
              (let* ((full (expand-file-name file path))
                     (tail (if (file-directory-p full) "/" ""))
                     (f (url-insert-entities-in-string file))
                     (l (url-hexify-string file)))
                (insert (format "<li><a href=\"%s%s\">%s%s</a></li>\n"
                                l tail f tail)))))
          (insert "</ul>\n<hr/>\n</body>\n</html>")
          (httpd-send-header proc "text/html; charset=utf-8" 200))
      (httpd-redirect proc (concat uri-path "/")))))

(defun httpd--buffer-size (&optional buffer)
  "Get the BUFFER size in bytes."
  (let ((orig enable-multibyte-characters)
        (size 0))
    (with-current-buffer (or buffer (current-buffer))
      (set-buffer-multibyte nil)
      (setf size (buffer-size))
      (if orig (set-buffer-multibyte orig)))
    size))

(defun httpd-error (proc status &optional info)
  "Send an error page appropriate for STATUS to the client.
The INFO object is optionally inserted into page.  If PROC is t use the
`httpd-current-proc' as the process."
  (httpd-discard-buffer)
  (httpd-log `(error ,status ,info))
  (with-temp-buffer
    (let ((html (or (cdr (assq status httpd-html)) ""))
          (contents
           (if (not info)
               ""
             (with-temp-buffer
               (let ((standard-output (current-buffer)))
                 (insert "error: ")
                 (princ info)
                 (insert "\n")
                 (when httpd-show-backtrace-when-error
                   (insert "backtrace: ")
                   (princ (backtrace))
                   (insert "\n"))
                 (httpd-escape-html-buffer)
                 (buffer-string))))))
      (insert (format html contents)))
    (httpd-send-header proc "text/html" status)))

(defun httpd--error-safe (&rest args)
  "Call `httpd-error' with ARGS and log failures to *httpd*."
  (condition-case error-case
      (apply #'httpd-error args)
    (error (httpd-log `(hard-error ,error-case)))))

(provide 'simple-httpd)
;;; simple-httpd.el ends here
