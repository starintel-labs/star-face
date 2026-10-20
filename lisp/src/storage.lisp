(in-package :star-face)

(defparameter *storage-root* (merge-pathnames "db/" *default-pathname-defaults*))

(defun db-path (dtype id)
  (let ((id-string (princ-to-string id)))
    (when (find-if (lambda (char) (member char '(#\/ #\\ #\Null))) id-string)
      (error "Invalid StarIntel id ~S." id-string))
    (merge-pathnames (make-pathname :directory (list :relative (princ-to-string dtype))
                                    :name id-string
                                    :type "ndjson")
                     *storage-root*)))

(defun ensure-parent-directory (path)
  (let ((dir (make-pathname :defaults path :name nil :type nil)))
    (ensure-directories-exist dir)))

(defun read-lines (path)
  (when (probe-file path)
    (with-open-file (stream path :direction :input)
      (loop for line = (read-line stream nil nil)
            while line
            when (plusp (length line))
              collect line))))

(defun load-document (dtype id)
  (let ((lines (read-lines (db-path dtype id))))
    (when lines
      (yason:parse (first (last lines)) :object-as :alist))))

(defun append-document (document)
  (let* ((id (cdr (assoc "_id" document :test #'string=)))
         (dtype (cdr (assoc "dtype" document :test #'string=)))
         (path (db-path dtype id))
         (line (encode-document-line document))
         (existing (read-lines path)))
    (ensure-parent-directory path)
    (when (and existing (string= (first (last existing)) line))
      (return-from append-document :duplicate))
    (with-open-file (stream path
                            :direction :output
                            :if-exists :append
                            :if-does-not-exist :create)
      (write-string line stream)
      (terpri stream))
    :appended))

(defun write-json (value stream)
  (typecase value
    (string (yason:encode value stream))
    ((or integer float) (yason:encode value stream))
    (symbol (if (eq value t)
                (write-string "true" stream)
                (write-string "[]" stream)))
    (vector (write-char #\[ stream)
            (loop for i across value
                  for firstp = t then nil
                  unless firstp do (write-char #\, stream)
                  do (write-json i stream))
            (write-char #\] stream))
    (cons (if (and (consp (first value)) (stringp (first (first value))))
              (progn
                (write-char #\{ stream)
                (loop for (key . rest) in value
                      for firstp = t then nil
                      unless firstp do (write-char #\, stream)
                      do (yason:encode (string key) stream)
                         (write-char #\: stream)
                         (write-json rest stream))
                (write-char #\} stream))
              (progn
                (write-char #\[ stream)
                (loop for item in value
                      for firstp = t then nil
                      unless firstp do (write-char #\, stream)
                      do (write-json item stream))
                (write-char #\] stream))))
    (t (error "Cannot encode ~S as JSON." value))))

(defun encode-document-line (document)
  (with-output-to-string (stream)
    (write-json document stream)))

(defun scan-dtype (dtype)
  (let ((dir (merge-pathnames (make-pathname :directory (list :relative (princ-to-string dtype)))
                              *storage-root*))
        (docs '()))
    (when (probe-file dir)
      (dolist (path (directory (merge-pathnames "*.ndjson" dir)))
        (let ((lines (read-lines path)))
          (when lines
            (push (yason:parse (first (last lines)) :object-as :alist) docs)))))
    docs))

(defun data-value (document key)
  (cdr (assoc key (cdr (assoc "data" document :test #'string=)) :test #'string=)))

(defun to-double (value)
  (cond ((stringp value)
         (with-standard-io-syntax
           (let ((*read-eval* nil))
             (coerce (read-from-string value) 'double-float))))
      (t (coerce value 'double-float))))

(defun cosine-similarity (a b)
  (let ((length (min (length a) (length b))))
    (when (plusp length)
      (let ((dot 0d0) (na 0d0) (nb 0d0))
        (loop for i below length
              for x = (to-double (elt a i))
              for y = (to-double (elt b i))
              do (incf dot (* x y))
                 (incf na (* x x))
                 (incf nb (* y y)))
        (if (and (plusp na) (plusp nb))
            (/ dot (sqrt (* na nb)))
            0d0)))))

(defun observation-embedding (document)
  (data-value document "embedding"))

(defun face-observation-p (document)
  (and (string= (cdr (assoc "dtype" document :test #'string=)) "observation")
       (string= (or (data-value document "observed_property") "") "face")))
