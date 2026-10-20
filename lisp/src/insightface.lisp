(in-package :star-face)

(define-condition malformed-face-result (error)
  ((message :initarg :message :reader malformed-face-result-message))
  (:report (lambda (condition stream)
             (write-string (malformed-face-result-message condition) stream))))

(defun fail-malformed (control &rest arguments)
  (error 'malformed-face-result :message (apply #'format nil control arguments)))

(defun json-items (value)
  "JSON array items as a plain list; Yason yields vectors or lists by configuration."
  (typecase value
    (vector (coerce value 'list))
    (list value)
    (t nil)))

(defun json-number-list (value context)
  (let ((items (json-items value)))
    (unless (and items (plusp (length items)))
      (fail-malformed "~A requires a non-empty array." context))
    (loop for item in items collect (coerce item 'double-float))))

(defun bbox-list (value context)
  (let ((numbers (json-number-list value context)))
    (unless (= (length numbers) 4)
      (fail-malformed "~A requires exactly four coordinates." context))
    (mapcar (lambda (n) (round n)) numbers)))

(defun landmark-point (pair)
  (let ((numbers (json-number-list pair "kps")))
    (unless (= (length numbers) 2)
      (fail-malformed "kps requires xy coordinate pairs."))
    (mapcar (lambda (n) (round n)) numbers)))

(defun landmarks-list (value)
  (loop for pair in (json-items value)
        append (landmark-point pair)))

(defun format-decimal (n &optional (digits 6))
  (format nil (format nil "~~,~DF" digits) (coerce n 'double-float)))

(defun string-key (value)
  (if (stringp value)
      value
      (fail-malformed "Expected a string, received ~S." value)))

(defun normalized-gender (value)
  (cond ((eql value 0) "female")
        ((eql value 1) "male")
        ((stringp value) value)
        (t nil)))

(defun normalize-face (raw index media-ref)
  (unless (hash-table-p raw)
    (fail-malformed "Face ~D is not a JSON object." index))
  (flet ((get-key (key) (gethash key raw)))
    (let ((bbox (or (get-key "bbox")
                    (fail-malformed "Face ~D is missing bbox." index)))
          (det-score (or (get-key "det_score")
                         (fail-malformed "Face ~D is missing det_score." index)))
          (embedding (or (get-key "embedding")
                         (fail-malformed "Face ~D is missing embedding." index))))
      (let ((landmarks (when (get-key "kps") (landmarks-list (get-key "kps"))))
            (embedding-values (json-number-list embedding "embedding")))
        (list :index index
              :bbox (bbox-list bbox "bbox")
              :landmarks landmarks
              :det-score (coerce det-score 'double-float)
              :embedding embedding-values
              :age (let ((age (get-key "age"))) (when age (round age)))
              :gender (normalized-gender (get-key "gender"))
              :detector (let ((d (get-key "detector"))) (when d (string-key d)))
              :media-ref media-ref)))))

(defun face-id (face)
  (let* ((embedding (getf face :embedding))
         (head (subseq embedding 0 (min 8 (length embedding))))
         (material
           (format nil "v1|~A|~D|~A|{~{~A~^,~}}"
                   (getf face :media-ref)
                   (getf face :index)
                   (format-decimal (getf face :det-score))
                   (mapcar #'format-decimal head))))
    (ironclad:byte-array-to-hex-string
     (ironclad:digest-sequence
      (ironclad:make-digest :sha256)
      (babel:string-to-octets material)))))

(defun parse-insightface-json (text media-ref)
  (let* ((parsed (yason:parse text))
         (items (json-items parsed)))
    (unless items
      (fail-malformed "InsightFace results must be a JSON array of face objects."))
    (loop for index from 0
          for raw in items
          collect (normalize-face raw index media-ref))))

(defun face->wire (face)
  (let ((face-id (face-id face)))
    (append
     (list (cons "id" face-id)
           (cons "faceId" face-id)
           (cons "dataset" *dataset*)
           (cons "dtype" "observation")
           (cons "schemaVersion" *schema-version*)
           (cons "mediaRef" (getf face :media-ref))
           (cons "bbox" (getf face :bbox))
           (cons "detScore" (format-decimal (getf face :det-score) 4))
           (cons "embedding" (mapcar #'format-decimal (getf face :embedding))))
     (when (getf face :landmarks)
       (list (cons "landmarks" (getf face :landmarks))))
     (when (getf face :age)
       (list (cons "ageEstimate" (getf face :age))))
     (when (getf face :gender)
       (list (cons "genderEstimate" (getf face :gender))))
     (when (getf face :detector)
       (list (cons "detector" (getf face :detector)))))))

(defun insightface->payload (text media-ref &key engine)
  (let ((faces (mapcar #'face->wire (parse-insightface-json text media-ref))))
    (append
     (list (cons "mediaRef" media-ref)
           (cons "faces" faces))
     (when engine (list (cons "engine" engine))))))
