(in-package :star-face)

(defparameter *dataset* "star-face")
(defparameter *schema-version* "0.9.0")
(defparameter *clock-function*
  (lambda ()
    (multiple-value-bind (second minute hour day month year)
        (decode-universal-time (get-universal-time) 0)
      (format nil "~4D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ"
              year month day hour minute second))))

(defun sha256-hex (string)
  (ironclad:byte-array-to-hex-string
   (ironclad:digest-sequence
    (ironclad:make-digest :sha256)
    (babel:string-to-octets string))))

(defun wire-value (payload key)
  (let ((entry (assoc key payload :test #'string=)))
    (when entry (cdr entry))))

(defun wire-list (payload key)
  (let ((value (wire-value payload key)))
    (cond ((null value) nil)
          ((vectorp value) (coerce value 'list))
          ((listp value) value)
          (t (fail-malformed "~A must be an array." key)))))

(defun required-wire (payload key)
  (or (wire-value payload key)
      (fail-malformed "Missing required field ~A." key)))

(defun face-count-check (faces media-ref)
  (declare (ignore media-ref))
  faces)

(defun observation-document (wire-face clock)
  (let* ((face-id (required-wire wire-face "faceId"))
         (media-ref (required-wire wire-face "mediaRef"))
         (data
           (append
            (list (cons "observed_property" "face")
                  (cons "measurement"
                        (append
                         (list (cons "det_score" (required-wire wire-face "detScore"))
                               (cons "bbox" (wire-list wire-face "bbox")))
                         (when (wire-value wire-face "landmarks")
                           (list (cons "landmarks" (wire-list wire-face "landmarks"))))))
                  (cons "embedding" (wire-list wire-face "embedding"))
                  (cons "media_ref" media-ref)
                  (cons "face_id" face-id))
            (when (wire-value wire-face "detector")
              (list (cons "detector" (wire-value wire-face "detector"))))
            (when (wire-value wire-face "ageEstimate")
              (list (cons "age_estimate" (wire-value wire-face "ageEstimate"))))
            (when (wire-value wire-face "genderEstimate")
              (list (cons "gender_estimate" (wire-value wire-face "genderEstimate"))))
            (when (wire-value wire-face "identitySimilarity")
              (list (cons "identity_similarity"
                          (wire-value wire-face "identitySimilarity"))))
            (when (wire-value wire-face "personRef")
              (list (cons "person_ref"
                          (cdr (assoc "id" (wire-value wire-face "personRef")
                                      :test #'string=))))))))
    (list (cons "_id" face-id)
          (cons "dataset" *dataset*)
          (cons "dtype" "observation")
          (cons "schema_version" *schema-version*)
          (cons "version" 1)
          (cons "date_added" clock)
          (cons "date_updated" clock)
          (cons "sources"
                (vector (list (cons "access_method" "facial-recognition")
                              (cons "locator" media-ref))))
          (cons "evidence" #())
          (cons "data" data))))

(defun media-document (payload faces clock)
  (let* ((media-ref (required-wire payload "mediaRef"))
         (id (sha256-hex (format nil "media|~A" media-ref))))
    (list (cons "_id" id)
          (cons "dataset" *dataset*)
          (cons "dtype" "media")
          (cons "schema_version" *schema-version*)
          (cons "version" 1)
          (cons "date_added" clock)
          (cons "date_updated" clock)
          (cons "sources"
                (vector (list (cons "access_method" "facial-recognition")
                              (cons "locator" media-ref))))
          (cons "evidence" #())
          (cons "data"
                (append
                 (list (cons "kind" "face-image")
                       (cons "media_ref" media-ref)
                       (cons "face_count" (length faces)))
                 (when (wire-value payload "engine")
                   (list (cons "engine" (wire-value payload "engine")))))))))

(defun derive-documents (payload &key (clock (funcall *clock-function*)))
  (let* ((media-ref (required-wire payload "mediaRef"))
         (faces (face-count-check (wire-list payload "faces") media-ref))
         (docs (list (media-document payload faces clock))))
    (dolist (face faces)
      (let ((person-ref (wire-value face "personRef")))
        (push (observation-document face clock) docs)
        (when person-ref
          (let* ((person-id (or (cdr (assoc "id" person-ref :test #'string=))
                                (fail-malformed "personRef requires id.")))
                 (similarity (wire-value face "identitySimilarity")))
            (push (list (cons "_id" person-id)
                        (cons "dataset" *dataset*)
                        (cons "dtype" "person")
                        (cons "schema_version" *schema-version*)
                        (cons "version" 1)
                        (cons "date_added" clock)
                        (cons "date_updated" clock)
                        (cons "sources" #())
                        (cons "evidence" #())
                        (cons "data"
                              (list (cons "identity_source" "facial-recognition"))))
                  docs)
            (push (list (cons "_id"
                              (sha256-hex (format nil "rel|~A|~A"
                                                  (required-wire face "faceId")
                                                  person-id)))
                        (cons "dataset" *dataset*)
                        (cons "dtype" "relation")
                        (cons "schema_version" *schema-version*)
                        (cons "version" 1)
                        (cons "date_added" clock)
                        (cons "date_updated" clock)
                        (cons "sources" #())
                        (cons "evidence" #())
                        (cons "data"
                              (append
                               (list (cons "source" (required-wire face "faceId"))
                                     (cons "destination" person-id)
                                     (cons "predicate" "face-identifies"))
                               (when similarity
                                 (list (cons "similarity" similarity))))))
                  docs)))))
    (nreverse docs)))
