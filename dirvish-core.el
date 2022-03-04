;;; dirvish-core.el --- Core data structures and utils for Dirvish -*- lexical-binding: t -*-

;; This file is NOT part of GNU Emacs.

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; This library contains core data structures and utils for Dirvish.

;;; Code:

(require 'dirvish-helpers)
(require 'face-remap)
(require 'ansi-color)
(require 'cl-lib)

(defun dirvish-curr (&optional frame)
  "Get current dirvish instance in FRAME.

FRAME defaults to current frame."
  (if dirvish--curr-name
      (gethash dirvish--curr-name (dirvish-hash))
    (frame-parameter frame 'dirvish--curr)))

(defun dirvish-drop (&optional frame)
  "Drop current dirvish instance in FRAME.

FRAME defaults to current frame."
  (set-frame-parameter frame 'dirvish--curr nil))

(defmacro dirvish--get-util-buffer (dv type &rest body)
  "Return dirvish session DV's utility buffer with TYPE.
If BODY is non-nil, create the buffer and execute BODY in it."
  (declare (indent defun))
  `(progn
     (let* ((id (dv-name ,dv))
            (h-name (format " *Dirvish-%s-%s*" ,type id))
            (buf (get-buffer-create h-name)))
       (with-current-buffer buf ,@body buf))))

(defun dirvish--init-util-buffers (dv)
  "Initialize util buffers for DV."
  (dirvish--get-util-buffer dv 'preview
    (setq-local mode-line-format nil)
    (add-hook 'window-scroll-functions #'dirvish-update-ansicolor-h nil :local))
  (dirvish--get-util-buffer dv 'header
    (setq-local header-line-format nil)
    (setq-local window-size-fixed 'height)
    (setq-local face-font-rescale-alist nil)
    (setq-local mode-line-format '((:eval (dirvish--apply-header-style))))
    (set (make-local-variable 'face-remapping-alist)
         `((mode-line-inactive :inherit (mode-line-active) :height ,dirvish-header-line-height))))
  (dirvish--get-util-buffer dv 'footer
    (setq-local header-line-format nil)
    (setq-local window-size-fixed 'height)
    (setq-local face-font-rescale-alist nil)
    (setq-local mode-line-format '((:eval (dirvish--format-mode-line))))
    (set (make-local-variable 'face-remapping-alist)
         '((mode-line-inactive mode-line-active)))))

(defun dirvish-reclaim (&optional _window)
  "Reclaim current dirvish."
  (unless (active-minibuffer-window)
    (if dirvish--curr-name
        (progn
          (dirvish--init-util-buffers (dirvish-curr))
          (or dirvish-override-dired-mode (dirvish--add-advices)))
      (or dirvish-override-dired-mode (dirvish--remove-advices)))
    (let ((dv (gethash dirvish--curr-name (dirvish-hash))))
      (set-frame-parameter nil 'dirvish--curr dv) dv)))

;;;###autoload
(cl-defmacro dirvish-define-attribute (name &key if form left right doc)
  "Define a Dirvish attribute NAME.

An attribute contains a pair of predicate/rendering functions
that are being called on `post-command-hook'.  The predicate fn
takes current session DV as argument and execute IF once.  When
IF evaluates to t, the rendering fn runs FORM for every line with
following arguments:

- `f-name'  from `dired-get-filename'
- `f-attrs' from `file-attributes'
- `f-beg'   from `dired-move-to-filename'
- `f-end'   from `dired-move-to-end-of-filename'
- `l-beg'   from `line-beginning-position'
- `l-end'   from `line-end-position'
- `hl-face' a face that is only passed in on current line
Optional keywords LEFT, RIGHT and DOC are supported."
  (declare (indent defun))
  (let* ((ov (intern (format "dirvish-%s-ov" name)))
         (pred (intern (format "dirvish-attribute-%s-pred" name)))
         (render (intern (format "dirvish-attribute-%s-rd" name)))
         (args '(f-name f-attrs f-beg f-end l-beg l-end hl-face))
         (pred-body (if (> (length if) 0) if t)))
    `(progn
       (add-to-list
        'dirvish--available-attrs
        (cons ',name '(:doc ,doc :left ,left :right ,right :overlay ,ov :if ,pred :fn ,render)))
       (defun ,pred (dv) (always dv) ,pred-body)
       (defun ,render ,args (always ,@args) (let ((ov ,form)) (and ov (overlay-put ov ',ov t)))))))

(defmacro dirvish-get-attribute-create (file attribute force &rest body)
  "Get FILE's ATTRIBUTE from `dirvish--attrs-alist'.
When FORCE or the attribute does not exist, set it with BODY."
  (declare (indent defun))
  `(let ((f-name ,file)
         (item (alist-get f-name dirvish--attrs-alist nil nil #'string=)))
     (unless item (push (list f-name :init t) dirvish--attrs-alist))
     (when (or ,force (not (plist-get item ,attribute)))
       (plist-put (alist-get f-name dirvish--attrs-alist nil nil #'string=) ,attribute ,@body))
     (plist-get (alist-get f-name dirvish--attrs-alist nil nil #'string=) ,attribute)))

(cl-defmacro dirvish-define-preview (name arglist &optional docstring &rest body)
  "Define a Dirvish preview dispatcher NAME.
A dirvish preview dispatcher is a function consumed by
`dirvish-preview-dispatch' which optionally takes
`file' (filename under the cursor) and `dv' (current Dirvish
session) as argument specified in ARGLIST.  DOCSTRING and BODY is
the docstring and body for this function."
  (declare (indent defun))
  (let* ((dp-name (intern (format "dirvish-%s-preview-dp" name)))
         (default-arglist '(file dv))
         (ignore-list (cl-set-difference default-arglist arglist)))
    `(progn (defun ,dp-name ,default-arglist ,docstring (ignore ,@ignore-list) ,@body))))

(defun dirvish-update-ansicolor-h (_win pos)
  "Update dirvish ansicolor in preview window from POS."
  (with-current-buffer (current-buffer)
    (ansi-color-apply-on-region
     pos (progn (goto-char pos) (forward-line (frame-height)) (point)))))

(defun dirvish-hash (&optional frame)
  "Return a hash containing all dirvish instance in FRAME.

The keys are the dirvish's names automatically generated by
`cl-gensym'.  The values are dirvish structs created by
`make-dirvish'.

FRAME defaults to the currently selected frame."
  ;; XXX: This must return a non-nil value to avoid breaking frames initialized
  ;; with after-make-frame-functions bound to nil.
  (or (frame-parameter frame 'dirvish--hash)
      (make-hash-table)))

(defun dirvish-get-all (slot &optional all-frame)
  "Gather slot value SLOT of all Dirvish in `dirvish-hash' as a flattened list.
If optional ALL-FRAME is non-nil, collect SLOT for all frames."
  (let* ((dv-slot (intern (format "dv-%s" slot)))
         (all-vals (if all-frame
                       (mapcar (lambda (fr)
                                 (with-selected-frame fr
                                   (mapcar dv-slot (hash-table-values (dirvish-hash)))))
                               (frame-list))
                     (mapcar dv-slot (hash-table-values (dirvish-hash))))))
    (delete-dups (flatten-tree all-vals))))

(cl-defstruct
    (dirvish
     (:conc-name dv-)
     (:constructor
      make-dirvish
      (&key
       (depth dirvish-depth)
       (transient nil)
       (type nil)
       (dedicated nil)
       &aux
       (fullscreen-depth (if (>= depth 0) depth dirvish-depth))
       (read-only-depth (if (>= depth 0) depth dirvish-depth))
       (root-window-fn (let ((fn (intern (format "dirvish-%s-root-window-fn" type))))
                         (if (functionp fn) fn #'frame-selected-window)))
       (header-string-fn (let ((fn (intern (format "dirvish-%s-header-string-fn" type))))
                         (if (functionp fn) fn (symbol-value 'dirvish-header-string-function))))
       (quit-window-fn (let ((fn (intern (format "dirvish-%s-quit-window-fn" type))))
                         (if (functionp fn) fn #'ignore))))))
  "Define dirvish data type."
  (name
   (cl-gensym)
   :documentation "is a symbol that is unique for every instance.")
  (depth
   dirvish-depth
   :documentation "TODO.")
  (fullscreen-depth
   dirvish-depth
   :documentation "TODO.")
  (read-only-depth
   dirvish-depth
   :read-only t :documentation "TODO.")
  (transient
   nil
   :documentation "TODO.")
  (type
   nil
   :documentation "TODO")
  (dedicated
   nil
   :documentation "TODO")
  (dired-buffers
   ()
   :documentation "holds all dired buffers in this instance.")
  (dired-windows
   ()
   :documentation "holds all dired windows in this instance.")
  (preview-window
   nil
   :documentation "is the window to display preview buffer.")
  (preview-buffers
   ()
   :documentation "holds all file preview buffers in this instance.")
  (window-conf
   (current-window-configuration)
   :documentation "is the window configuration given by `current-window-configuration'.")
  (root-window-fn
   #'frame-selected-window
   :documentation "is the main dirvish window.")
  (header-string-fn
   (symbol-value 'dirvish-header-string-function)
   :documentation "TODO.")
  (quit-window-fn
   #'ignore
   :documentation "TODO.")
  (root-window
   nil
   :documentation "is the main dirvish window.")
  (root-dir-buf-alist
   ()
   :documentation "TODO.")
  (attributes-alist
   ()
   :documentation "TODO.")
  (index-path
   ""
   :documentation "is the file path under cursor in ROOT-WINDOW.")
  (preview-dispatchers
   dirvish-preview-dispatchers
   :documentation "Preview dispatchers used for preview in this instance.")
  (ls-switches
   dired-listing-switches
   :documentation "is the list switches passed to `ls' command.")
  (sort-criteria
   (cons "default" "")
   :documentation "is the addtional sorting flag added to `dired-list-switches'."))

(defmacro dirvish-new (&rest args)
  "Create a new dirvish struct and put it into `dirvish-hash'.

ARGS is a list of keyword arguments followed by an optional BODY.
The keyword arguments set the fields of the dirvish struct.
If BODY is given, it is executed to set the window configuration
for the dirvish.

Save point, and current buffer before executing BODY, and then
restore them after."
  (declare (indent defun))
  (let ((keywords))
    (while (keywordp (car args))
      (dotimes (_ 2) (push (pop args) keywords)))
    (setq keywords (reverse keywords))
    `(let ((dv (make-dirvish ,@keywords)))
       (unless (frame-parameter nil 'dirvish--hash)
         (add-hook 'window-selection-change-functions #'dirvish-reclaim)
         (set-frame-parameter nil 'dirvish--hash (make-hash-table :test 'equal)))
       (puthash (dv-name dv) dv (dirvish-hash))
       ,(when args `(save-excursion ,@args)) ; Body form given
       dv)))

(defmacro dirvish-kill (dv &rest body)
  "Kill a dirvish instance DV and remove it from `dirvish-hash'.

DV defaults to current dirvish instance if not given.  If BODY is
given, it is executed to unset the window configuration brought
by this instance."
  (declare (indent defun))
  `(unwind-protect
       (let ((conf (dv-window-conf ,dv)))
         (when (and (not (dirvish-dired-p ,dv)) (window-configuration-p conf))
           (set-window-configuration conf))
         (setq dirvish-transient-dvs (delete dv dirvish-transient-dvs))
         (cl-labels ((kill-when-live (b) (and (buffer-live-p b) (kill-buffer b))))
           (mapc #'kill-when-live (dv-dired-buffers ,dv))
           (mapc #'kill-when-live (dv-preview-buffers ,dv))
           (dolist (type '(preview footer header)) (kill-when-live (dirvish--get-util-buffer ,dv type))))
         (funcall (dv-quit-window-fn ,dv) ,dv))
     (remhash (dv-name ,dv) (dirvish-hash))
     (dirvish-reclaim)
     ,@body))

(defun dirvish--end-transient (tran)
  "End transient of Dirvish instance or name TRAN."
  (cl-loop
   with hash = (dirvish-hash)
   with tran-dv = (if (dirvish-p tran) tran (gethash tran hash))
   for dv-name in (mapcar #'dv-name (hash-table-values hash))
   for dv = (gethash dv-name hash)
   for dv-tran = (dv-transient dv) do
   (when (or (eq dv-tran tran) (eq dv-tran tran-dv))
     (dirvish-kill dv))
   finally (dirvish-deactivate tran-dv)))

(defun dirvish--create-root-window (dv)
  "Create root window of DV."
  (let ((depth (dv-depth dv))
        (r-win (funcall (dv-root-window-fn dv))))
    (when (and (>= depth 0) (window-parameter r-win 'window-side))
      (setq r-win (next-window)))
    (setf (dv-root-window dv) r-win)
    r-win))

(defun dirvish--enlarge (&rest _)
  "Kill all dirvish parent windows except the root one."
  (when (dirvish-curr)
    (cl-dolist (win (dv-dired-windows (dirvish-curr)))
      (and (not (eq win (dv-root-window (dirvish-curr))))
           (window-live-p win)
           (delete-window win)))))

(defun dirvish--refresh-slots (dv)
  "Update dynamic slot values of DV."
  (when dirvish-attributes (mapc #'require dirvish-extra-libs))
  (let* ((attr-names (append dirvish-built-in-attrs dirvish-attributes))
         (attrs-alist
          (cl-loop for name in attr-names
                   for attr = (cdr-safe (assoc name dirvish--available-attrs))
                   collect (cl-destructuring-bind (&key overlay if fn left right &allow-other-keys)
                               attr (list overlay if fn left right))))
         (preview-dps
          (cl-loop for dp-name in (append '(disable) dirvish-preview-dispatchers '(default))
                   for dp-func-name = (intern (format "dirvish-%s-preview-dp" dp-name))
                   collect dp-func-name)))
    (setf (dv-attributes-alist dv) attrs-alist)
    (setf (dv-preview-dispatchers dv) preview-dps)
    (unless (dirvish-dired-p dv) (setf (dv-depth dv) (dv-read-only-depth dv)))
    (setf (dv-fullscreen-depth dv) (dv-read-only-depth dv))))

(defun dirvish--apply-header-style ()
  "Format Dirvish header line."
  (when-let ((dv (dirvish-curr)))
    (let* ((h-fn (dv-header-string-fn dv))
           (str (format-mode-line `((:eval (funcall #',h-fn)))))
           (large-header-p (eq dirvish-header-style 'large))
           (ht (if large-header-p 1.2 1))
           (win-width (1- (* (frame-width) (- 1 dirvish-preview-width))))
           (max-width (floor (/ win-width ht))))
      (while (>= (+ (length str) (/ (- (string-bytes str) (length str)) 2)) (1- max-width))
        (setq str (substring str 0 -1)))
      (propertize str 'display `((height ,ht) (raise ,(if large-header-p 0.25 0.35)))))))

(defun dirvish--format-mode-line ()
  "Generate Dirvish mode line string."
  (when (dirvish-curr)
    (cl-destructuring-bind (left . right) dirvish-mode-line-format
      (let ((fmt-right (format-mode-line right)))
        (concat (format-mode-line left)
                (propertize " " 'display
                            `((space :align-to (- (+ right right-fringe right-margin)
                                                  ,(string-width fmt-right)))))
                fmt-right)))))

(defun dirvish--buffer-for-dir (dv entry)
  "Return the dirvish buffer in DV for ENTRY.
If the buffer is not available, create it with `dired-noselect'."
  (let* ((root-dir-buf (dv-root-dir-buf-alist dv))
         (buffer (alist-get entry root-dir-buf nil nil #'equal))
         (sorter (cdr (dv-sort-criteria dv)))
         (switches (string-join (list (dv-ls-switches dv) sorter) " ")))
    (unless buffer
      (setq buffer (dired-noselect entry switches))
      (push (cons entry buffer) (dv-root-dir-buf-alist dv)))
    buffer))

(defun dirvish-activate (dv)
  "Activate dirvish instance DV."
  (setq tab-bar-new-tab-choice "*scratch*")
  (when-let (old-dv (dirvish-curr))
    (cond ((dv-transient dv) nil)
          ((and (not (dirvish-dired-p old-dv))
                (not (dirvish-dired-p dv)))
           (dirvish-deactivate dv)
           (user-error "Dirvish: using current session"))
          ((memq (selected-window) (dv-dired-windows old-dv))
           (dirvish-deactivate old-dv))))
  (dirvish--refresh-slots dv)
  (dirvish--create-root-window dv)
  (set-frame-parameter nil 'dirvish--curr dv)
  (run-hooks 'dirvish-activation-hook)
  dv)

(defun dirvish-deactivate (dv)
  "Deactivate dirvish instance DV."
  (dirvish-kill dv
    (unless (dirvish-get-all 'name t)
      (setq other-window-scroll-buffer nil)
      (setq tab-bar-new-tab-choice dirvish-saved-new-tab-choice)
      (dolist (tm dirvish-repeat-timers) (cancel-timer (symbol-value tm)))))
  (run-hooks 'dirvish-deactivation-hook)
  (and dirvish-debug-p (message "leftover: %s" (dirvish-get-all 'name t))))

(defun dirvish-dired-p (&optional dv)
  "Return t if DV is a `dirvish-dired' instance.
DV defaults to the current dirvish instance if not provided."
  (when-let ((dv (or dv (dirvish-curr)))) (eq (dv-depth dv) -1)))

(defun dirvish-live-p (&optional dv)
  "Return t if selected window is occupied by Dirvish DV.
DV defaults to the current dirvish instance if not provided."
  (when-let ((dv (or dv (dirvish-curr)))) (memq (selected-window) (dv-dired-windows dv))))

(provide 'dirvish-core)
;;; dirvish-core.el ends here