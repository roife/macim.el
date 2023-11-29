;;; mac-im.el  --- SIS with dynamic module support   -*- lexical-binding: t; -*-

;; Copyright (C) 2023 Roife Wu

;; Author: Roife Wu <roifewu@gmail.com>
;; URL: https://github.com/roife/mac-im.el
;; Version: 0.0.1
;; Package-Requires: ((emacs "29.1"))
;; Keywords: macOS, input method, Chinese

;; This file is NOT a part of GNU Emacs.

;; This file is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; For a full copy of the GNU General Public License
;; see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This package is similar to https://github.com/laishulu/emacs-smart-input-source,
;; but it uses dynamic module to switch input source.

;;; Code:

(eval-when-compile (require 'cl-lib))

(defgroup macim nil
  "Group for macim."
  :group 'macim)

(defconst macim-version "v0.0.1")

(defface macim-inline-face
  '((t (:inherit (font-lock-constant-face) :inverse-video t)))
  "Face of the inline region overlay."
  :group 'macim)

(defcustom macim-lib-path (concat user-emacs-directory "modules/libMacIM" module-file-suffix)
  "The path to the directory of dynamic library for macim."
  :type 'string
  :group 'macim)

(defcustom macim-ascii "com.apple.keylayout.ABC"
  "The name of the ASCII input source."
  :type 'string
  :group 'macim)

(defvar macim-inline-activated-hook nil
  "Hook run when the inline region overlay is activated.")

(defvar macim-inline-deactivated-hook nil
  "Hook run when the inline region overlay is deactivated.")

(defcustom macim-other "com.apple.inputmethod.SCIM.Shuangpin"
  "The name of the Other input source."
  :type 'string
  :group 'macim)

(defvar macim-context-early-predicates nil
  "Early predicate to detect the context.

It is called before computations of `sis--back-detect-chars' and
`sis--fore-detect-chars', which enhances performance.

Each detector is called without arguments and returns one of the following:
- nil: left the determination to later detectors.
- `'ascii': English context.
- `'other': other language context.")

(defvar macim-context-predicates
  '(macim--context-ascii-wrapper
    macim--context-other-wrapper)
  "Predicate to detect the context.

Each detector should:
- have two arguments:
  - back-detect: which is the result of (sis--back-detect-chars).
  - fore-detect: which is the result of (sis--fore-detect-chars).
- return one of the following values:
  - nil: left the determination to later detectors.
  - `'english': English context.
  - `'other': other language context.")

(defvar macim-inline-head-handler nil
  "Function to delete head spaces.

The cursor will be moved to the beginning of the inline region, and the function
will be called with the end position of the leading whitespaces in region.")

(defvar macim-inline-tail-handler nil
  "Function to delete tail spaces.

The cursor will be moved to the end of the inline region, and the function will
be called with the beginning position of the tailing whitespaces in region.")

(defvar macim--root (file-name-directory (or load-file-name buffer-file-name))
  "The path to the root of the package.")

(defvar macim--lib-fns
  '(macim-set macim-get)
  "The list of functions in dynamic module.")

(defvar-keymap macim--inline-map
  :doc "Keymap used in inline mode."
  "<remap> RET" #'macim--inline-deactive
  "<remap> <return>" #'macim--inline-deactive)

(defvar macim--ascii-pattern "[a-zA-Z]"
  "Pattern to identify a character as english.")

(defvar macim--other-pattern "\\cc"
  "Pattern to identify a character as other lang.")

(defvar macim-blank-pattern "[:blank:]"
  "Pattern to identify a character as blank.")

(defvar macim--lib-loaded nil
  "Whether dynamic module for macim is loaded.")

(defvar-local macim--inline-ov nil
  "The active inline overlay.")

(defvar macim--kbd-map (make-hash-table :test 'equal)
  "The hashtable to store the mapping from Chinese composition keys to ASCII keys.")

(cl-loop for prefix in '("C-" "M-" "s-" "H-" "ESC ")
         do (cl-loop
             for epunc in '("," "." "?" "!" ";" ":" "\\" "(" ")" "[" "]" "<" ">" "_")
             for cpunc in '("，" "。" "？" "！" "；" "：" "、" "（" "）" "【" "】" "《" "》" "—")
             do (puthash (kbd (concat prefix epunc)) (kbd (concat prefix cpunc)) macim--kbd-map)))

;;; helper

(defsubst macim-select-ascii ()
  "Select the ASCII-capable keyboard input source.

Expects to be added to normal hooks."
  (macim-set macim-ascii))

(defsubst macim-select-other ()
  "Select the other input source defined by `macim-other'."
  (macim-set macim-other))

(defsubst macim--ascii-p (str)
  "Predicate on STR is has no English characters."
  (and str (string-match-p macim--ascii-pattern str)))

(defsubst macim--other-p (str)
  "Predicate on STR has /other/ language characters."
  (and str (string-match-p macim--other-pattern str)))

; to: point after first non-blank char in the same line
; char: first non-blank char at the same line (just before position `to')
; cross-line-to: point after first non-blank char cross lines
; cross-line-char: first non-blank char cross lines before the current position
(cl-defstruct macim--back-detect-res to char cross-line-to cross-line-char)
(defun macim--back-detect-chars ()
  "Detect char backward:

First backward skip blank in current line,
then backward skip blank across lines."
  (save-excursion
    (skip-chars-backward macim-blank-pattern)
    (let ((to (point))
          (char (char-before (point))))
      (skip-chars-backward (concat macim-blank-pattern "[:cntrl:]"))
      (let ((cross-line-char (char-before (point))))
        (make-macim--back-detect-res
         :to to
         :char (when char (string char))
         :cross-line-to (point)
         :cross-line-char (when cross-line-char
                            (string cross-line-char)))))))

; to: point before first non-blank char in the same line
; char: first non-blank char at the same line (just after position `to')
; cross-line-to: point before first non-blank char cross lines
; cross-line-char: first non-blank char cross lines after the current position
(cl-defstruct macim--fore-detect-res to char cross-line-to cross-line-char)
(defun macim--fore-detect-chars ()
  "Detect char forward.

Forward skip blank in the current line."
  (save-excursion
    (skip-chars-forward macim-blank-pattern)
    (let ((to (point))
          (char (char-after (point))))
      (skip-chars-forward (concat macim-blank-pattern "[:cntrl:]"))
      (let ((cross-line-char (char-after (point))))
        (make-macim--fore-detect-res
         :to to
         :char (when char (string char))
         :cross-line-to (point)
         :cross-line-char (when cross-line-char
                            (string cross-line-char)))))))

;;; kbd

(defun macim-kbd-switch-and-resend (&optional _prompt)
  "Switch to ascii input source and resend the last input event.
Expects to be bound to global keymap's prefix keys in `input-decode-map'."
  (macim-select-ascii)
  (vector last-input-event))

(defun macim--enable-kdb-switching ()
  "Enable key-mapping to switch to ascii input source and send composition keys."
  (map-keymap (lambda (event definition)
                (if (and (keymapp definition) (integerp event) (not (eq event ?\e)))
                    (let ((ckbd (gethash (vector event) macim--kbd-map)))
                      (when ckbd (define-key input-decode-map ckbd 'macim-kbd-switch-and-resend))
                      (define-key input-decode-map (vector event) 'macim-kbd-switch-and-resend))))
              global-map)

  (map-keymap (lambda (event definition)
                (if (and (keymapp definition) (integerp event) (not (eq event ?\e)))
                    (let ((ckbd (gethash (vector ?\e event) macim--kbd-map)))
                      (when ckbd (define-key input-decode-map ckbd 'macim-kbd-switch-and-resend))
                      (define-key input-decode-map (vector ?\e event) 'macim-kbd-switch-and-resend))))
              esc-map)
  (add-hook 'minibuffer-setup-hook 'macim-select-ascii))

(defun macim--disable-kbd-switching ()
  "Disable key-mapping to switch to ascii input source and send composition keys."
  (map-keymap (lambda (event definition)
                (if (and (keymapp definition) (integerp event) (not (eq event ?\e)))
                    (let ((ckbd (gethash (vector event) macim--kbd-map)))
                      (when ckbd (keymap-unset input-decode-map (key-description ckbd) t))
                      (keymap-unset input-decode-map (key-description (vector event)) t))))
              global-map)

  (map-keymap (lambda (event definition)
                (if (and (keymapp definition) (integerp event) (not (eq event ?\e)))
                    (let ((ckbd (gethash (vector ?\e event) macim--kbd-map)))
                      (when ckbd (keymap-unset input-decode-map (key-description ckbd) t))
                      (keymap-unset input-decode-map (key-description (vector ?\e event)) t))))
              esc-map)
  (remove-hook 'minibuffer-setup-hook 'macim-select-ascii))

;;; context

(defun macim--context-other-p (back-detect fore-detect &optional position)
  "Predicate for context of other language.

`back-detect' BACK-DETECT and `fore-detect' FORE-DETECT are required.
If POSITION is not provided, then default to be the current position."
  (let* ((back-to (macim--back-detect-res-to back-detect))
         (back-char (macim--back-detect-res-char back-detect))
         (cross-line-back-to (macim--back-detect-res-cross-line-to back-detect))
         (cross-line-back-char (macim--back-detect-res-cross-line-char back-detect))

         (fore-to (macim--fore-detect-res-to fore-detect))
         (fore-char (macim--fore-detect-res-char fore-detect)))
    (or
     ; [other]^
     (and (= back-to (or position (point))) (macim--other-p back-char))
     ; ^[other]
     (and (= fore-to (or position (point))) (macim--other-p fore-char))
     ; [other lang][blank or not][^][blank or not][not english]
     (and (macim--other-p back-char) (macim--ascii-p fore-char))
     ; [not english][blank or not][^][blank or not][other lang]
     (and (macim--ascii-p back-char) (macim--other-p fore-char))
     ; [other lang: to the previous line][blank][^]
     (and (< cross-line-back-to (line-beginning-position))
          (macim--other-p cross-line-back-char)))))

(defun macim--context-ascii-p (back-detect fore-detect &optional position)
  "Predicate for context of English.

`back-detect' BACK-DETECT and `fore-detect' FORE-DETECT are required.
If POSITION is not provided, then default to be the current position."
  (let* ((back-to (macim--back-detect-res-to back-detect))
         (back-char (macim--back-detect-res-char back-detect))
         (cross-line-back-to (macim--back-detect-res-cross-line-to back-detect))
         (cross-line-back-char (macim--back-detect-res-cross-line-char back-detect))

         (fore-to (macim--fore-detect-res-to fore-detect))
         (fore-char (macim--fore-detect-res-char fore-detect)))
    (or
     ; [english]^
     (and (= back-to (or position (point))) (macim--ascii-p back-char))
     ; ^[english]
     (and (= fore-to (or position (point))) (macim--ascii-p fore-char))
     ; [english][blank or not][^][blank or not][not other]
     (and (macim--ascii-p back-char) (macim--other-p fore-char))
     ; [not other][blank or not][^][blank or not][english]
     (and (macim--other-p back-char) (macim--ascii-p fore-char))
     ; [english: to the previous line][blank][^]
     (and (< cross-line-back-to (line-beginning-position))
          (macim--ascii-p cross-line-back-char)))))

(defsubst macim--context-ascii-wrapper (back-detect fore-detect)
  "Wrapper for `macim--context-ascii-p'.

BACK-DETECT and FORE-DETECT are arguments of `macim--context-ascii-p'."
  (when (macim--context-ascii-p back-detect fore-detect)
    'ascii))

(defsubst macim--context-other-wrapper (back-detect fore-detect)
  "Wrapper for `macim--context-other-p'.

BACK-DETECT and FORE-DETECT are arguments of `macim--context-other-p'."
  (when (macim--context-other-p back-detect fore-detect)
    'other))

(defun macim-context-switch ()
  "Switch input source with context.

Using predicates in `macim-context-early-predicates' and
`macim-context-predicates'."
  (let ((im (cl-loop for predicate in macim-context-early-predicates
                         for result = (funcall predicate)
                         while (not (memq result '(ascii other)))
                         finally return result)))
    (unless im
      (setq im
            (let* ((back-detect (macim--back-detect-chars))
                   (fore-detect (macim--fore-detect-chars)))
              (cl-loop for predicate in macim-context-predicates
                       for result = (funcall predicate back-detect fore-detect)
                       while (not (memq result '(ascii other)))
                       finally return result))))
    (cond ((eq im 'ascii) (macim-select-ascii))
          ((eq im 'other) (macim-select-other)))))

;;; inline

(defun macim--inline-activation-check ()
  "Check whether to activate the inline region overlay.

Check the context to determine whether the overlay should be activated or not,
if the answer is yes, then activate the /inline region/, set the
input source to ascii."
  (when (and (or (eq (preceding-char) ?\s)
                 (eq (preceding-char) 12288)) ;; around char is <spc> <DBC spc>
             (not macim--inline-ov)
             (not (button-at (point))))
    (let* ((back-detect (macim--back-detect-chars))
           (fore-detect (macim--fore-detect-chars)))
      (when (and (macim--context-other-p back-detect fore-detect (1- (point)))
                 (equal (macim-get) macim-other))
        (macim--inline-activate (1- (point)))))))

(defun macim--inline-activate (start)
  "Activate the inline region overlay."

  (setq macim--inline-ov (make-overlay start (point) nil t t))
  (overlay-put macim--inline-ov 'face 'macim-inline-face)
  (overlay-put macim--inline-ov 'keymap 'macim--inline-map)

  (macim-select-ascii)
  (run-hooks 'macim-inline-activated-hook)
  (add-hook 'post-command-hook #'macim--inline-flycheck-deactivate nil t))

(defun macim--inline-flycheck-deactivate ()
  "Check whether to deactivate the inline region overlay."
  (when (overlayp macim--inline-ov)
    ;; When cursor is at point-max, may display with a huge inline overlay.
    (when (= (point) (point-max))
        (save-excursion (insert-char ?\n)))

    ;; Some package insert \n before EOF, then kick \n out of the overlay
    (when (and (= (char-before (overlay-end macim--inline-ov)) ?\n)
               (< (overlay-start macim--inline-ov)
                  (overlay-end macim--inline-ov)))
      (move-overlay macim--inline-ov
                    (overlay-start macim--inline-ov)
                    (1- (overlay-end macim--inline-ov))))

    ;; select input source
    (let* ((back-detect (macim--back-detect-chars))
           (back-to (macim--back-detect-res-to back-detect)))
      (when (or (= (overlay-start macim--inline-ov) (overlay-end macim--inline-ov)) ;; zero length overlay
                ;; out of range
                (or (< (point) (overlay-start macim--inline-ov))
                    (> (point) (overlay-end macim--inline-ov)))
                ;; " inline  ^", but not "           ^"
                (and (= (point) (overlay-end macim--inline-ov))
                     (> back-to (overlay-start macim--inline-ov))
                     (= (+ back-to 2) ;; deactivate with 2 spaces
                        (point))))
        (macim--inline-deactive)))))

(defun macim--inline-deactive ()
  "Deactivate the inline region overlay."
  (when (overlayp macim--inline-ov)
    (remove-hook 'post-command-hook #'macim--inline-flycheck-deactivate t)

    ;; select input source
    (let* ((back-detect (macim--back-detect-chars))
           (back-to (macim--back-detect-res-to back-detect)))

      (macim-select-other)

      ;; only tighten for none-blank inline region
      (when (and (<= (point) (overlay-end macim--inline-ov))
                 (> back-to (overlay-start macim--inline-ov)))
        (save-excursion
          (goto-char (overlay-end macim--inline-ov))
          (let ((tighten-back-to (macim--back-detect-res-to (macim--back-detect-chars))))
            (when (and macim-inline-tail-handler
                       (<= tighten-back-to (overlay-end macim--inline-ov))
                       (> tighten-back-to (overlay-start macim--inline-ov)))
              (funcall macim-inline-tail-handler tighten-back-to)))

          (goto-char (overlay-start macim--inline-ov))
          (let ((tighten-fore-to (macim--fore-detect-res-to (macim--fore-detect-chars))))
            (when (and macim-inline-head-handler
                       (> tighten-fore-to (overlay-start macim--inline-ov)))
              (funcall macim-inline-head-handler tighten-fore-to))))))

    (delete-overlay macim--inline-ov)
    (setq macim--inline-ov nil)

    (run-hooks 'macim-inline-deactivated-hook)))

;;; macim-mode

;;;###autoload
(defun macim-download-module (&optional path)
  "Download dynamic module from GitHub.

If PATH is non-nil, download the module to PATH."
  (interactive)
  (unless (eq system-type 'darwin)
    (error "Only support macOS"))
  (setq path (or path macim-lib-path))
  (make-directory (file-name-directory path) t)
  (let ((url (format "https://github.com/roife/mac-im.el/releases/download/%s/libMacIM.dylib" macim-version)))
    (url-copy-file url path t)))

;;;###autoload
(defun macim-compile-module (&optional path)
  "Compile dynamic module.

If PATH is non-nil, compile the module to PATH."
  (interactive)
  (unless (eq system-type 'darwin)
    (error "Only support macOS"))
  (unless module-file-suffix
    (error "Variable `module-file-suffix' is nil"))
  (unless (executable-find "swift")
    (error "Swift compiler not found"))
  (unless (file-directory-p (concat macim--root "module/"))
    (error "No module source found"))
  (unless (file-exists-p "/Applications/Xcode.app")
    (error "Xcode not found. You can download pre-compiled module from GitHub"))

  (shell-command (concat "echo "
                         (shell-quote-argument (read-passwd "sudo password (required by compiling MacIM):"))
                         " | sudo -S xcode-select --switch /Applications/Xcode.app/Contents/Developer"))

  (setq path (or path macim-lib-path))
  (let ((default-directory (concat macim--root "module/")))
    (if (zerop (shell-command "swift build -c release"))
        (progn (message "Compile succeed!")
               (make-directory (file-name-directory path) t)
               (copy-file (concat macim--root "module/.build/release/libMacIM" module-file-suffix)
                          path t))
      (error "Compile dynamic module failed"))))

;;;###autoload
(defun macim-ensure ()
  "Load the dynamic library."
  (interactive)
  (unless macim--lib-loaded
    (unless (file-exists-p macim-lib-path)
      (if (yes-or-no-p "MacIM module not found. Download pre-built from GitHub?")
          (macim-download-module)
        (if (yes-or-no-p "Compile MacIM module from source?")
            (macim-compile-module)
          (error "MacIM module cannot be loaded"))))
    (load-file macim-lib-path)
    (dolist (fn macim--lib-fns)
      (unless (fboundp fn)
        (error "No %s function found in dynamic module" fn)))
    (setq macim--lib-loaded t)))

;;;###autoload
(define-minor-mode macim-mode
  "Toggle macim-mode."
  :global t
  :init-value nil
  (if macim-mode
      (progn
        (macim-ensure)
        (macim--enable-kdb-switching)
        (add-hook 'post-self-insert-hook #'macim--inline-activation-check))
    (macim--disable-kbd-switching)
    (remove-hook 'post-self-insert-hook #'macim--inline-activation-check)))

(provide 'macim)


;;; macim.el ends here
