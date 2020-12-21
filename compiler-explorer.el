;;; compiler-explorer.el --- Compiler explorer client (godbolt.org)  -*- lexical-binding: t; -*-

;; Copyright (C) 2020  Michał Krzywkowski

;; Author: Michał Krzywkowski <k.michal@zoho.com>
;; Keywords: c, tools
;; Version: 0.1.0
;; Homepage: https://github.com/mkcms/compiler-explorer.el
;; Package-Requires: ((emacs "26.1") (request "0.3.0"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;;
;;; compiler-explorer.el
;;
;; Package that provides a simple client for [compiler
;; explorer][compiler-explorer] service.
;;
;;
;;; Usage
;;
;; M-x `compiler-explorer' is the main entry point.  It will ask you
;; for a language and display source&compilation buffers.  Type
;; something in the source buffer; the compilation buffer will
;; automatically update with compiled asm code.  Another buffer
;; displays output of the compiled and executed program.
;;
;; M-x `compiler-explorer-set-compiler' changes the compiler for
;;current session.
;;
;; M-x `compiler-explorer-set-compiler-args' sets compilation options.
;;
;; M-x `compiler-explorer-add-library' asks for a library version and
;; adds it to current compilation.  M-x
;; `compiler-explorer-remove-library' removes them.
;;
;; M-x `compiler-explorer-set-execution-args' sets the arguments for
;; the executied program.
;;
;; M-x `compiler-explorer-set-input' reads a string from minibuffer
;; that will be used as input for the executed program.
;;
;; M-x `compiler-explorer-new-session' kills the current session and
;; creates a new one, asking for source language.
;;
;; M-x `compiler-explorer-previous-session' lets you cycle between
;; previous sessions.
;;
;; M-x `compiler-explorer-make-link' generates a link for current
;; compilation so it can be opened in a browser and shared.
;;
;; M-x `compiler-explorer-layout' cycles between different layouts.
;;
;;
;; [compiler-explorer]: https://godbolt.org/

;;; Code:

(require 'ansi-color)
(require 'browse-url)
(require 'compile)
(require 'json)
(require 'request)
(require 'ring)
(require 'seq)
(require 'subr-x)

(defgroup compiler-explorer nil "Client for compiler-explorer service."
  :group 'tools)


;; API

(defvar compiler-explorer-url "https://godbolt.org")

(defun compiler-explorer--url (&rest chunks)
  (concat compiler-explorer-url "/api/" (string-join chunks "/")))

(defun compiler-explorer--parse-json ()
  (let ((json-object-type 'plist))
    (json-read)))

(defvar compiler-explorer--languages nil)
(defun compiler-explorer--languages ()
  "Get all languages."
  (or compiler-explorer--languages
      (setq compiler-explorer--languages
            (request-response-data
             (request (compiler-explorer--url "languages")
               :sync t
               :params '(("fields" . "all"))
               :headers '(("Accept" . "application/json"))
               :parser #'compiler-explorer--parse-json)))))

(defvar compiler-explorer--compilers nil)
(defun compiler-explorer--compilers ()
  "Get all compilers."
  (or compiler-explorer--compilers
      (setq compiler-explorer--compilers
            (request-response-data
             (request (compiler-explorer--url "compilers")
               :sync t
               ;; :params '(("fields" . "all"))
               :headers '(("Accept" . "application/json"))
               :parser #'compiler-explorer--parse-json)))))

(defvar compiler-explorer--libraries (make-hash-table :test #'equal))
(defun compiler-explorer--libraries (id)
  "Get available libraries for language ID."
  (or (map-elt compiler-explorer--libraries id)
      (setf (map-elt compiler-explorer--libraries id)
            (request-response-data
             (request (compiler-explorer--url "libraries" id)
               :sync t
               :headers '(("Accept" . "application/json"))
               :parser #'compiler-explorer--parse-json)))))


;; Compilation

(defconst compiler-explorer--buffer "*compiler-explorer*"
  "Buffer with source code.")

(defconst compiler-explorer--compiler-buffer "*compiler-explorer compilation*"
  "Buffer with ASM code.")

(defconst compiler-explorer--output-buffer "*compiler-explorer output*"
  "Combined compiler stdout&stderr.")

(defconst compiler-explorer--exe-output-buffer
  "*compiler-explorer execution output*"
  "Buffer with execution output.")

(defvar compiler-explorer--language-data nil
  "Language data for current session.")

(defvar compiler-explorer--compiler-data nil
  "Compiler data for current session.")

(defvar compiler-explorer--selected-libraries nil
  "Alist of libraries for current session.
Keys are library ids, values are versions.")

(defvar compiler-explorer--compiler-arguments ""
  "Arguments for the compiler.")

(defvar compiler-explorer--execution-arguments ""
  "Arguments for the program executed.")

(defvar compiler-explorer--execution-input ""
  "Stdin for the program executed.")

(defvar compiler-explorer--recompile-timer nil
  "Timer for recompilation.")

(defvar compiler-explorer--last-compilation-request nil
  "Last request (response) for current compilation.")

(defvar compiler-explorer--last-exe-request nil
  "Last request (response) for current execution.")

(defvar compiler-explorer-response-limit-bytes (* 1000 1000)
  "Limit in bytes for responses to compilation requests.
If a compilation response is larger than this, it is not parsed
with `json-parse', and a message is displayed.")

(defun compiler-explorer--parse-json-compilation ()
  "Parse current buffer as json, but only if it's size is reasonable."
  (cond
   ((< (buffer-size) compiler-explorer-response-limit-bytes)
    (compiler-explorer--parse-json))
   (t
    `(:asm [(:text ,(format
                     "ERROR: Response too large to parse. (%s kB, limit %s kB)"
                     (/ (buffer-size) 1000)
                     (/ compiler-explorer-response-limit-bytes 1000)))
            (:text "Increase the limit by setting ")
            (:text "`compiler-explorer-response-limit-bytes'")]))))

(defcustom compiler-explorer-output-filters '(:binary nil
                                                      :commentOnly t
                                                      :demangle t
                                                      :directives t
                                                      :intel t
                                                      :labels t
                                                      :libraryCode t
                                                      :trim nil)
  "Compiler output filters."
  :type '(plist :key-type (choice
                           (const :tag "Compile to binary" :binary)
                           (const :tag "Comments" :commentOnly)
                           (const :tag "Demangle C++ symbols" :demangle)
                           (const :tag "Directives" :directives)
                           (const :tag "Intel ASM syntax" :intel)
                           (const :tag "Unused labels" :labels)
                           (const :tag "Library code" :libraryCode)
                           (const :tag "Trim whitespace" :trim))
                :value-type boolean))

(defun compiler-explorer--output-filters ()
  (mapcar (lambda (v) (or v :json-false)) compiler-explorer-output-filters))

(defun compiler-explorer--request-async ()
  "Queue compilation and execution and return immediately.
This calls `compiler-explorer--handle-compilation-response' and
`compiler-explorer--handle-execution-response' once the responses arrive."
  (pcase-dolist (`(,executorRequest ,symbol ,handler)
                 `((:json-false
                    compiler-explorer--last-compilation-request
                    compiler-explorer--handle-compilation-response)
                   (t
                    compiler-explorer--last-exe-request
                    compiler-explorer--handle-execution-response)))
    (when-let ((last (symbol-value symbol)))
      ;; Abort last request
      (unless (request-response-done-p last)
        (request-abort last)))
    (set symbol
         (request (compiler-explorer--url
                   "compiler" (plist-get compiler-explorer--compiler-data :id)
                   "compile")
           :type "POST"
           :headers '(("Accept" . "application/json")
                      ("Content-Type" . "application/json"))
           :data (let ((json-object-type 'plist))
                   (json-encode
                    `(
                      :source ,(with-current-buffer compiler-explorer--buffer
                                 (buffer-string))
                      :options
                      (
                       :userArguments ,compiler-explorer--compiler-arguments
                       :executeParameters
                       (
                        :args ,compiler-explorer--execution-arguments
                        :stdin ,compiler-explorer--execution-input)
                       :compilerOptions
                       (
                        :skipAsm :json-false
                        :executorRequest ,executorRequest)
                       :filters ,(compiler-explorer--output-filters)
                       :tools []
                       :libraries [,@(mapcar
                                      (pcase-lambda (`(,id . ,version))
                                        `(:id ,id :version ,version))
                                      compiler-explorer--selected-libraries)])
                      :allowStoreCodeDebug nil)))
           :parser #'compiler-explorer--parse-json-compilation
           :complete (lambda (&rest _args) (force-mode-line-update t))
           :error #'ignore              ;Error is displayed in the mode-line
           :success handler)))
  (force-mode-line-update))

(defvar compiler-explorer--project-dir)

(cl-defun compiler-explorer--handle-compilation-response
    (&key data &allow-other-keys)
  (cl-destructuring-bind (&key asm stdout stderr code &allow-other-keys) data
    (let ((compiler (get-buffer compiler-explorer--compiler-buffer))
          (output (get-buffer-create compiler-explorer--output-buffer)))
      (with-current-buffer compiler
        (let ((buffer-read-only nil))
          (erase-buffer)
          (insert (mapconcat (lambda (line) (plist-get line :text)) asm "\n"))))

      ;; Update output buffer
      (with-current-buffer output
        (let ((buffer-read-only nil))
          (erase-buffer)
          (save-excursion
            (insert (ansi-color-apply
                     (mapconcat (lambda (line) (plist-get line :text))
                                stdout "\n"))
                    "\n")
            (insert (ansi-color-apply
                     (mapconcat (lambda (line) (plist-get line :text))
                                stderr "\n"))
                    "\n")
            (insert (format "Compiler exited with code %s" code))))

        (setq buffer-read-only t)
        (unless (eq major-mode 'compilation-mode)
          (compilation-mode)
          (setq buffer-undo-list t))
        (compiler-explorer-mode +1)
        (when compiler-explorer--project-dir
          (setq-local default-directory compiler-explorer--project-dir)
          (setq-local compilation-parse-errors-filename-function
                      #'compiler-explorer--compilation-parse-errors-filename))
        (with-demoted-errors "compilation-parse-errors: %s"
          (let ((buffer-read-only nil))
            (compilation-parse-errors (point-min) (point-max)))))))
  (force-mode-line-update t))

(cl-defun compiler-explorer--handle-execution-response
    (&key data &allow-other-keys)
  (cl-destructuring-bind (&key stdout stderr code &allow-other-keys) data
    (with-current-buffer (get-buffer-create compiler-explorer--exe-output-buffer)
      (compiler-explorer-mode +1)
      (setq buffer-read-only t)
      (setq buffer-undo-list t)
      (setq header-line-format
            `(:eval (compiler-explorer--header-line-format-executor)))
      (let ((buffer-read-only nil))
        (erase-buffer)
        (save-excursion
          (insert "Program stdout:\n")
          (insert (mapconcat (lambda (line) (plist-get line :text))
                             stdout "\n")
                  "\n")
          (insert "Program stderr:\n")
          (insert (mapconcat (lambda (line) (plist-get line :text))
                             stderr "\n")
                  "\n")
          (insert (format "Program exited with code %s" code)))))))

(defun compiler-explorer--mode-line-format ()
  "Get the mode line format for `compiler-explorer-mode'."
  (let ((resp compiler-explorer--last-compilation-request))
    (propertize
     (concat "CE: "
             (cond
              ((null resp) "")
              ((not (request-response-done-p resp)) "Wait...")
              ((request-response-error-thrown resp)
               (propertize "ERROR" 'face 'error
                           'help-echo (format
                                       "Status: %s\nCode: %s\nError: %s"
                                       (request-response-symbol-status resp)
                                       (request-response-status-code resp)
                                       (request-response-error-thrown resp))))
              (t
               (cl-destructuring-bind (&key stdout stderr &allow-other-keys)
                   (request-response-data resp)
                 (propertize
                  (format "%s (%s/%s)"
                          (propertize "Done" 'face 'success)
                          (length stdout)
                          (propertize (format "%s" (length stderr))
                                      'face (if (> (length stderr) 0) 'error)))
                  'help-echo (with-current-buffer
                                 compiler-explorer--output-buffer
                               ;; Get at most 30 output lines
                               (save-excursion
                                 (goto-char (point-min))
                                 (forward-line 30)
                                 (concat (buffer-substring (point-min)
                                                           (point-at-bol))
                                         (unless (= (point-at-bol) (point-max))
                                           (concat "... message truncated. "
                                                   "See output buffer to "
                                                   "show all.\n"))
                                         "\nmouse-1: "
                                         " Show output buffer."))))))))
     'mouse-face 'mode-line-highlight
     'keymap (let ((map (make-keymap)))
               (define-key map [mode-line mouse-1]
                 #'compiler-explorer-show-output)
               map))))

(defvar compiler-explorer--mode-line-format
  `(:eval (compiler-explorer--mode-line-format)))
(put 'compiler-explorer--mode-line-format 'risky-local-variable t)

(add-to-list 'mode-line-misc-info
             '(compiler-explorer-mode
               (" [" compiler-explorer--mode-line-format "] ")))

(defun compiler-explorer--header-line-format-compiler ()
  "Get mode line construct for displaying header line in compilation buffers."
  `(
    ,(propertize
      (plist-get compiler-explorer--compiler-data :name)
      'mouse-face 'header-line-highlight
      'keymap (let ((map (make-keymap)))
                (define-key map [header-line mouse-1]
                  #'compiler-explorer-set-compiler)
                map)
      'help-echo "mouse-1: Select compiler")
    " "
    ,(propertize
      (format "Libs: %s"  (length compiler-explorer--selected-libraries))
      'mouse-face 'header-line-highlight
      'keymap (let ((map (make-keymap)))
                (define-key map [header-line mouse-1] #'compiler-explorer-add-library)
                (define-key map [header-line mouse-2] #'compiler-explorer-remove-library)
                map)
      'help-echo (concat "Libraries:\n"
                         (mapconcat (pcase-lambda (`(,name . ,vid))
                                      (concat name " " vid))
                                    compiler-explorer--selected-libraries
                                    "\n")
                         "\n\n"
                         "mouse-1: Add library\n"
                         "mouse-2: Remove library\n"))
    " "
    ,(propertize (format "Arguments: '%s'" compiler-explorer--compiler-arguments)
                 'mouse-face 'header-line-highlight
                 'keymap (let ((map (make-keymap)))
                           (define-key map [header-line mouse-1]
                             #'compiler-explorer-set-compiler-args)
                           map)
                 'help-echo "mouse-1: Set arguments")))

(defun compiler-explorer--header-line-format-executor ()
  "Get mode line construct for displaying header line in execution buffers."
  `(
    ,(propertize
      (format "Input: %s chars" (length compiler-explorer--execution-input))
      'mouse-face 'header-line-highlight
      'keymap (let ((map (make-keymap)))
                (define-key map [header-line mouse-1]
                  #'compiler-explorer-set-input)
                map)
      'help-echo "mouse-1: Set program input")
    " "
    ,(propertize
      (format "Arguments: '%s'" compiler-explorer--execution-arguments)
      'mouse-face 'header-line-highlight
      'keymap (let ((map (make-keymap)))
                (define-key map [header-line mouse-1]
                  #'compiler-explorer-set-execution-args)
                map)
      'help-echo "mouse-1: Set program arguments")))

(defun compiler-explorer--after-change (&rest _args)
  (when compiler-explorer--recompile-timer
    (cancel-timer compiler-explorer--recompile-timer))
  (setq compiler-explorer--recompile-timer
        (run-with-timer 0.5 nil #'compiler-explorer--request-async))

  ;; Prevent 'kill anyway?' when killing the buffer.
  (restore-buffer-modified-p nil))

(defvar compiler-explorer--last-session)

(defun compiler-explorer--cleanup ()
  "Kill current session."
  (when (buffer-live-p (get-buffer compiler-explorer--buffer))
    ;; Save last session.  Don't insert it into the ring, as that would make us
    ;; cycle between only 2 sessions when calling
    ;; `compiler-explorer-previous-session'.
    (setq compiler-explorer--last-session (compiler-explorer--current-session)))

  ;; Abort last request and cancel the timer for recompilation.
  (when-let ((req compiler-explorer--last-compilation-request))
    (unless (request-response-done-p req)
      (request-abort req)))
  (when-let ((req compiler-explorer--last-exe-request))
    (unless (request-response-done-p req)
      (request-abort req)))
  (setq compiler-explorer--last-compilation-request nil)
  (when compiler-explorer--recompile-timer
    (cancel-timer compiler-explorer--recompile-timer)
    (setq compiler-explorer--recompile-timer nil))

  (mapc (lambda (buffer)
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (let ((kill-buffer-hook
                     (remq #'compiler-explorer--cleanup kill-buffer-hook)))
                (kill-buffer (current-buffer))))))
        (list (get-buffer compiler-explorer--buffer)
              (get-buffer compiler-explorer--compiler-buffer)
              (get-buffer compiler-explorer--output-buffer)
              (get-buffer compiler-explorer--exe-output-buffer)))
  (setq compiler-explorer--compiler-data nil)
  (setq compiler-explorer--selected-libraries nil)
  (setq compiler-explorer--language-data nil)
  (setq compiler-explorer--compiler-arguments "")
  (setq compiler-explorer--execution-arguments "")
  (setq compiler-explorer--execution-input "")

  (with-demoted-errors "compiler-explorer--cleanup: delete-directory: %s"
    (when compiler-explorer--project-dir
      (delete-directory compiler-explorer--project-dir t)))
  (setq compiler-explorer--project-dir nil))


;; Stuff/hacks for integration with other packages

(defcustom compiler-explorer-make-temp-file t
  "If non-nil, make a temporary file/dir for a `compiler-explorer' session.
This is required for integration with some other packages, for
example `compilation-mode' - with this, you can navigate to
errors in the source buffer by clicking on the links in compiler
output buffer.

This also sets up a transient project for the source buffer, so
you can use packages that require one.

When the session is killed, the temporary directory is deleted."
  :type 'boolean)

(defvar compiler-explorer--project-dir nil)
(defun compiler-explorer--project-find-function (_dir)
  (and compiler-explorer--project-dir
       `(transient . ,compiler-explorer--project-dir)))

(defvar compiler-explorer--filename-regexp "<source>\\|\\(example[.][^.]+$\\)")
(defun compiler-explorer--compilation-parse-errors-filename
    (filename)
  (when (string-match-p compiler-explorer--filename-regexp filename)
    (file-name-nondirectory
     (buffer-file-name (get-buffer compiler-explorer--buffer)))))


;; Session management

(defcustom compiler-explorer-sessions-file
  (expand-file-name "compiler-explorer" user-emacs-directory)
  "File where sessions are persisted."
  :type 'file)

(defcustom compiler-explorer-sessions 5
  "Size of the session ring."
  :type 'integer)

(defvar compiler-explorer--session-ring
  (let ((ring (make-ring compiler-explorer-sessions)))
    (ignore-errors
      (with-temp-buffer
        (insert-file-contents compiler-explorer-sessions-file)
        (let ((elts (read (current-buffer))))
          (dolist (e elts)
            (ring-insert ring e)))))
    ring))

(defun compiler-explorer--current-session ()
  `(
    :lang-name ,(plist-get compiler-explorer--language-data :name)
    :compiler ,(plist-get compiler-explorer--compiler-data :id)
    :libs ,compiler-explorer--selected-libraries
    :args ,compiler-explorer--compiler-arguments
    :exe-args ,compiler-explorer--execution-arguments
    :input ,compiler-explorer--execution-input
    :source ,(with-current-buffer (get-buffer compiler-explorer--buffer)
               (buffer-substring-no-properties (point-min) (point-max)))))

(defun compiler-explorer--restore-session (session)
  (cl-destructuring-bind
      (&key lang-name compiler libs args exe-args input source) session
    (compiler-explorer-new-session lang-name compiler)
    (with-current-buffer (get-buffer compiler-explorer--buffer)
      (let ((inhibit-modification-hooks t))
        (erase-buffer)
        (insert source)
        (set-buffer-modified-p nil)))
    (setq compiler-explorer--selected-libraries libs)
    (setq compiler-explorer--compiler-arguments args)
    (setq compiler-explorer--execution-arguments exe-args)
    (setq compiler-explorer--execution-input input)))

(defvar compiler-explorer--last-session nil)

(defun compiler-explorer--save-sessions ()
  "Save all sessions to a file."
  (let ((current-session
         (or (and (get-buffer compiler-explorer--buffer)
                  (compiler-explorer--current-session))
             compiler-explorer--last-session)))
    (when current-session
      (ring-insert compiler-explorer--session-ring current-session))
    (with-temp-file compiler-explorer-sessions-file
      (print (ring-elements compiler-explorer--session-ring)
             (current-buffer)))))

(add-hook 'kill-emacs-hook #'compiler-explorer--save-sessions)


;; User commands & modes

(define-minor-mode compiler-explorer-mode ""
  :lighter " CE"
  (cond
   (compiler-explorer-mode
    (add-hook 'kill-buffer-hook #'compiler-explorer--cleanup nil t)
    (add-hook 'project-find-functions
              #'compiler-explorer--project-find-function nil t))
   (t
    (remove-hook 'kill-buffer-hook #'compiler-explorer--cleanup t)
    (remove-hook 'project-find-functions
                 #'compiler-explorer--project-find-function t))))

(defun compiler-explorer-show-output ()
  "Show compiler stdout&stderr buffer."
  (interactive)
  (display-buffer compiler-explorer--output-buffer))

(defun compiler-explorer-set-input (input)
  "Set the input to use as stdin for execution to INPUT, a string."
  (interactive (list
                (read-from-minibuffer "Stdin: "
                                      compiler-explorer--execution-input)))
  (setq compiler-explorer--execution-input input)
  (compiler-explorer--request-async))

(defvar compiler-explorer-set-compiler-args-history nil
  "Minibuffer history for `compiler-explorer-set-compiler-args'.")

(defun compiler-explorer-set-compiler-args (args)
  "Set compilation arguments to the string ARGS and recompile."
  (interactive (list (read-from-minibuffer
                      "Compiler arguments: "
                      compiler-explorer--compiler-arguments
                      nil nil 'compiler-explorer-set-compiler-args-history)))
  (setq compiler-explorer--compiler-arguments args)
  (compiler-explorer--request-async))

(defun compiler-explorer-set-execution-args (args)
  "Set execution arguments to the string ARGS and recompile."
  (interactive (list (read-from-minibuffer
                      "Execution arguments: "
                      compiler-explorer--execution-arguments)))
  (setq compiler-explorer--execution-arguments args)
  (compiler-explorer--request-async))

(defun compiler-explorer-set-compiler (name-or-id)
  "Select compiler NAME-OR-ID for current session."
  (interactive
   (let* ((lang (or compiler-explorer--language-data
                    (user-error "Not in a compiler-explorer session")))
          (default (plist-get lang :defaultCompiler))
          (compilers (mapcar (lambda (c) `(,(plist-get c :name)
                                           ,(plist-get c :id)
                                           ,(plist-get c :lang)))
                             (compiler-explorer--compilers))))
     (list (completing-read "Compiler: " compilers
                            ;; Only compilers for current language
                            (pcase-lambda (`(_ _ ,lang-id))
                              (string= lang-id (plist-get lang :id)))
                            t
                            (car (cl-find default compilers
                                          :test #'string= :key #'cadr))))))
  (unless compiler-explorer--language-data
    (error "Not in a `compiler-explorer' session"))
  (let* ((lang-data compiler-explorer--language-data)
         (lang (plist-get lang-data :id))
         (name-or-id (or name-or-id (plist-get lang-data :defaultCompiler)))
         (compiler-data (seq-find
                         (lambda (c)
                           (and
                            (member name-or-id (list (plist-get c :id)
                                                     (plist-get c :name)))
                            (string= (plist-get c :lang) lang)))
                         (compiler-explorer--compilers))))
    (unless compiler-data
      (error "No compiler %S for lang %S" name-or-id lang))
    (setq compiler-explorer--compiler-data compiler-data)
    (with-current-buffer (get-buffer-create compiler-explorer--compiler-buffer)
      (asm-mode)

      (compiler-explorer-mode +1)

      (setq buffer-read-only t)
      (setq buffer-undo-list t)
      (setq truncate-lines t)
      (setq header-line-format
            `(:eval (compiler-explorer--header-line-format-compiler)))

      (compiler-explorer--request-async)

      (pop-to-buffer (current-buffer)))))

(defun compiler-explorer-add-library (id version-id)
  "Add library ID with VERSION-ID to current compilation."
  (interactive
   (let* ((lang (or (plist-get compiler-explorer--language-data :id)
                    (user-error "Not in a compiler-explorer session")))
          (candidates (cl-reduce #'nconc
                                 (mapcar
                                  (lambda (l)
                                    (let ((libname (plist-get l :name))
                                          (lib-id (plist-get l :id)))
                                      (seq-map
                                       (lambda (v)
                                         (let ((version (plist-get v :version))
                                               (vid (plist-get v :id)))
                                           `(,(concat libname " " version)
                                             ,lib-id ,vid)))
                                       (plist-get l :versions))))
                                  (compiler-explorer--libraries lang))))
          (res (completing-read
                "Add library: " candidates
                ;; Ignore libraries that are already added.
                (pcase-lambda (`(,_ ,id ,_))
                  (null (assoc id compiler-explorer--selected-libraries)))
                t)))
     (cdr (assoc res candidates))))
  ;; TODO: check if arguments make sense
  (push (cons id version-id) compiler-explorer--selected-libraries)
  (compiler-explorer--request-async))

(defun compiler-explorer-remove-library (id)
  "Remove library with ID.
It must have previously been added with
`compiler-explorer-add-library'."
  (interactive
   (list (completing-read "Remove library: "
                          compiler-explorer--selected-libraries
                          nil t)))
  (setq compiler-explorer--selected-libraries
        (delq (assoc id compiler-explorer--selected-libraries)
              compiler-explorer--selected-libraries))
  (compiler-explorer--request-async))

(defun compiler-explorer-previous-session ()
  "Cycle between previous sessions, latest first."
  (interactive)
  (when (and (ring-empty-p compiler-explorer--session-ring)
             (null compiler-explorer--last-session))
    (error "No previous sessions"))
  (let ((prev (or compiler-explorer--last-session
                  (ring-remove compiler-explorer--session-ring))))
    (setq compiler-explorer--last-session nil)
    (compiler-explorer--restore-session prev)
    (compiler-explorer--request-async)))

(defvar compiler-explorer-layouts
  '((source . asm)
    (source . [asm output])
    (source [asm output] . exe))
  "List of layouts.

A layout can be either:

  - a symbol (one of `source', `asm', `output', `exe')
    means fill the available space with that buffer
  - a cons (left . right) - recursively apply layouts
    left and right after splitting available space horizontally
  - a vector [upper lower] - recursively apply layouts
    above and below after splitting available space vertically
  - a number, n - apply n-th layout in this variable")

(defcustom compiler-explorer-default-layout 0
  "The default layout to use.
See `compiler-explorer-layouts' for available layouts."
  :type 'sexp)

(defvar compiler-explorer--last-layout 0)

(defun compiler-explorer-layout (&optional layout)
  "Layout current frame.
Interactively, applies layout defined in variable
`compiler-explorer-default-layout'.  When this command is called
repeatedly (`repeat'), it will cycle between all layouts in
`compiler-explorer-layouts'.

LAYOUT must be as described in `compiler-explorer-layouts'."
  (interactive
   (list
    (or (and (numberp current-prefix-arg) current-prefix-arg)
        (when (eq last-command #'compiler-explorer-layout)
          (1+ compiler-explorer--last-layout)))))
  (cl-labels
      ((do-it
        (spec)
        (pcase-exhaustive spec
          ((and (pred numberp) n)
           (do-it (nth n compiler-explorer-layouts)))
          ('source (set-window-buffer (selected-window)
                                      compiler-explorer--buffer))
          ('asm (set-window-buffer (selected-window)
                                   compiler-explorer--compiler-buffer))
          ('output (set-window-buffer
                    (selected-window)
                    (get-buffer-create compiler-explorer--output-buffer)))
          ('exe (set-window-buffer
                 (selected-window)
                 (get-buffer-create compiler-explorer--exe-output-buffer)))
          (`(,left . ,right)
           (let ((right-window (split-window-right)))
             (do-it left)
             (with-selected-window right-window
               (do-it right))))
          (`[,upper ,lower]
           (let ((lower-window (split-window-vertically)))
             (do-it upper)
             (with-selected-window lower-window
               (do-it lower)))))))
    (or layout (setq layout compiler-explorer-default-layout))
    (when (numberp layout)
      (setq layout (% layout (length compiler-explorer-layouts)))
      (setq compiler-explorer--last-layout layout))
    (delete-other-windows)
    (do-it layout)
    (balance-windows)))

(defun compiler-explorer-make-link (&optional open)
  "Save URL to current session in the kill ring.
With an optional prefix argument OPEN, open that link in a browser."
  (interactive "P")
  (let* ((compiler
          `(
            :id ,(plist-get compiler-explorer--compiler-data :id)
            :libs [,@(mapcar
                      (pcase-lambda (`(,id . ,version))
                        `(:id ,id :version ,version))
                      compiler-explorer--selected-libraries)]
            :options ,compiler-explorer--compiler-arguments
            :filters ,(compiler-explorer--output-filters)))
         (state
          `(:sessions
            [(
              :id 1
              :language ,(plist-get compiler-explorer--language-data :id)
              :source ,(with-current-buffer
                           (get-buffer compiler-explorer--buffer)
                         (buffer-string))
              :compilers [,compiler]
              :executors [
                          (
                           :arguments ,compiler-explorer--execution-arguments
                           :compiler ,compiler
                           :stdin ,compiler-explorer--execution-input)
                          ])]))
         (response
          (request-response-data
           (request (concat compiler-explorer-url "/shortener")
             :sync t
             :type "POST"
             :headers '(("Accept" . "application/json")
                        ("Content-Type" . "application/json"))
             :data (let ((json-object-type 'plist))
                     (json-encode state))
             :parser #'compiler-explorer--parse-json)))
         (url (plist-get response :url)))
    (message (kill-new url))
    (when open (browse-url-xdg-open url))))

(defvar compiler-explorer-new-session-hook '(compiler-explorer-layout)
  "Hook run after creating new session.
The source buffer is current when this hook runs.")

(defun compiler-explorer-new-session (lang &optional compiler)
  "Create a new compiler-explorer session with language named LANG.
If COMPILER (name or id) is non-nil, set that compiler.

If a session already exists, it is killed and saved to the
session ring.

Always runs hooks in `compiler-explorer-new-session-hook' at the
end, with the source buffer as current."
  (interactive
   (list (completing-read "Language: "
                          (mapcar (lambda (lang) (plist-get lang :name))
                                  (compiler-explorer--languages))
                          nil t)
         nil))
  (compiler-explorer--cleanup)
  (when-let ((session compiler-explorer--last-session))
    (ring-insert compiler-explorer--session-ring session)
    (setq compiler-explorer--last-session nil))

  (let* ((lang-data (or (seq-find
                         (lambda (l) (string= (plist-get l :name) lang))
                         (compiler-explorer--languages))
                        (error "Language %S does not exist" lang)))
         (extensions (plist-get lang-data :extensions)))
    (setq compiler-explorer--language-data lang-data)

    (with-current-buffer (generate-new-buffer compiler-explorer--buffer)
      ;; Find major mode by extension
      (cl-loop for ext across extensions
               for filename = (concat "test" ext)
               while (eq major-mode 'fundamental-mode)
               do (let ((buffer-file-name filename)) (set-auto-mode)))

      (insert (plist-get lang-data :example))
      (add-hook 'after-change-functions #'compiler-explorer--after-change nil t)
      (compiler-explorer-mode +1)
      (save-current-buffer (compiler-explorer-set-compiler compiler))

      (when compiler-explorer-make-temp-file
        (setq compiler-explorer--project-dir
              (make-temp-file "compiler-explorer" 'dir))
        (setq buffer-file-name
              (expand-file-name (concat "source" (aref extensions 0))
                                compiler-explorer--project-dir))
        (let ((save-silently t)) (save-buffer)))

      (pop-to-buffer (current-buffer))
      (run-hooks 'compiler-explorer-new-session-hook))))

(defvar compiler-explorer-hook '(compiler-explorer-layout)
  "Hook run at the end of `compiler-explorer'.
This hook can be used to run code regardless whether a session
was created/restored.")

;;;###autoload
(defun compiler-explorer ()
  "Open a compiler-explorer session.
If a live session exists, just pop to the source buffer.
If there are saved sessions, restore the last one.
Otherwise, create a new session (`compiler-explorer-new-session').

The hook `compiler-explorer-hook' is always run at the end."
  (interactive)
  (let ((buffer (get-buffer compiler-explorer--buffer)))
    (cond
     (buffer (pop-to-buffer buffer) (compiler-explorer--request-async))
     ((or compiler-explorer--last-session
          (not (ring-empty-p compiler-explorer--session-ring)))
      (compiler-explorer-previous-session))
     (t (call-interactively #'compiler-explorer-new-session))))
  (run-hooks 'compiler-explorer-hook))

(provide 'compiler-explorer)
;;; compiler-explorer.el ends here

;; Local Variables:
;; indent-tabs-mode: nil
;; End:
