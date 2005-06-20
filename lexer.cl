(in-package :python)

;; Lexer

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :yacc)
  (use-package :yacc))


(defvar *lex-read-char*)
(defvar *lex-unread-char*)

(defvar *lex-debug* nil)
(defvar *tab-width-spaces* 8)


(defun make-py-lexer (&key (read-chr   (lambda () (read-char *standard-input* nil nil t)))
			   (unread-chr (lambda (c) (unread-char c *standard-input*))))
  "Return a lexer for the Python grammar.

READ-CHAR is a function that returns either a character or NIL (it should not signal ~
an error on eof).

UNREAD-CHAR is a function of one character that ensures the next call to READ-CHAR
returns the given character. UNREAD-CHAR is called at most once between two calls of
READ-CHAR."
  (let ((tokens-todo ())
	(indentation-stack (list 0))
	(open-lists ()))
    
    (lambda (grammar &optional op)
      (declare (ignore grammar op))
      
      (let ((*lex-read-char* read-chr)
	    (*lex-unread-char* unread-chr))
	(block lexer

	  (when tokens-todo
	    (let ((item (pop tokens-todo)))
	      (when *lex-debug*
		(format t "lexer returns: ~s  (from todo)~%" (car item)))
	      (return-from lexer (apply #'values item))))

	  (with-terminal-codes (python-grammar)
	    
	    (macrolet ((lex-todo (val1 val2) ;; (lex-todo name <value>)
			 `(let ((eval2 ,val2))
			    (when *lex-debug*
			      (format t "lexer todo: ~s~%" eval2))
			    (push (list (tcode ,val1) eval2) tokens-todo)))
		       
		       (lex-return (val1 val2) ;; (lex-return name <value>)
			 `(let ((eval2 ,val2))
			    (when *lex-debug*
			      (format t "lexer returns: ~s ~s~%" ',val1 eval2))
			    (return-from lexer (values (tcode ,val1) eval2))))
		       
		       (find-token-code (token) ;; (find-token-code name)
			 `(tcode-1 (load-time-value
				    (find-class 'python-grammar)) ,token)))
	      
	      (tagbody next-char
		(let ((c (read-chr-nil)))
		  
		  (cond

		   ((not c)
		    ;; Before returning EOF, return a NEWLINE followed
		    ;; by a DEDENT for every currently active indent.
		    
		    (lex-todo eof 'eof)
		    (loop while (> (car indentation-stack) 0)
			do (pop indentation-stack)
			   (lex-todo dedent 'dedent))
		    (lex-return newline 'newline))
		   
		   
		   ((digit-char-p c 10)
		    (lex-return number (read-number c)))

		   ((identifier-char1-p c)
		    (let ((token (read-identifier c)))
		      (assert (symbolp token))
		      
		      (cond ((member token '(u r ur U R UR))
			     ;; u"abc"    : `u' stands for `Unicode string'
			     ;; u + b     : `u' is an identifier
			     ;; r"s/f\af" : `r' stands for `raw string'
			     ;; r + b     : `r' is an identifier
			     ;; ur"asdf"  : `ur' stands for `raw unicode string'
			     ;; ur + a    : `ur' is identifier
			     ;; `u' must appear before 'r' if both are present
			     
			     (let ((ch (read-chr-nil)))
			       (if (char-member ch '(#\' #\"))
				   
				   (let ((is-unicode
					  (member token '(u ur U UR)))
					 (is-raw
					  (member token '(r ur R UR))))
				     (lex-return string
						 (read-string ch :unicode is-unicode :raw is-raw)))
				 (progn
				   (when ch (unread-chr ch))
				   (lex-return identifier token)))))
			    
			    ((reserved-word-p token)
			     (when *lex-debug*
			       (format t "lexer returns: reserved word ~s~%" token))
			     (return-from lexer
			       (values (find-token-code token) token)))
			    
			    (t
			     #+(or)(when *lex-debug*
			       (format t "lexer returns: identifier: ~s~%" read-id))
			     (lex-return identifier token)))))

		   ((char-member c '(#\' #\"))
		    (lex-return string (read-string c)))

		   ((or (punct-char1-p c)
			(punct-char-not-punct-char1-p c))
		    (let ((token (read-punctuation c)))
		      
		      ;; Keep track of whether we are in a bracketed
		      ;; expression (list, tuple or dict), because in
		      ;; that case newlines are ignored. (Note that
		      ;; READ-STRING handles multi-line strings itself.)
		      ;; 
		      ;; There is no check for matching brackets here:
		      ;; left to the grammar.
		      
		      (case token
			(( [ { \( ) (push token open-lists))
			(( ] } \) ) (pop open-lists)))
		      
		      (when *lex-debug*
			(format t "lexer returns: punctuation token ~s~%" token))
		      (return-from lexer 
			(values (find-token-code token) token))))

		   ((char-member c '(#\Space #\Tab #\Newline #\Return))
		    (unread-chr c)
		    (multiple-value-bind (newline new-indent)
			(read-whitespace)
		      
		      (when (or (not newline) open-lists)
			(go next-char))
		      
		      ;; Return Newline now, but also determine if
		      ;; there are any indents or dedents to be
		      ;; returned in next calls.
		      
		      (cond
		       ((= (car indentation-stack) new-indent)) ;; same level

		       ((< (car indentation-stack) new-indent) ; one indent
			(push new-indent indentation-stack)
			(lex-todo indent 'indent))

		       ((> (car indentation-stack) new-indent) ; dedent(s)
			(loop while (> (car indentation-stack) new-indent)
			    do (pop indentation-stack)
			       (lex-todo dedent 'dedent))
			
			(unless (= (car indentation-stack) new-indent)
			  (raise-syntax-error
			   "Dedent didn't arrive at a previous indentation level ~
                          (indent level after dedent: ~A spaces)" new-indent))))
		      
		      (lex-return newline 'newline)))
		   
		   ((char= c #\#) ;; comment to end-of-line
		    (read-comment-line c)
		    (go next-char))

		   ((char= c #\\) ;; next line is continuation of this one
		    (let ((c2 (read-chr-nil)))
		      (if (and c2 (char= c2 #\Newline))
			  (go next-char)
			(raise-syntax-error 
			 "Syntax error: continuation character \\ ~
                        must be followed by Newline, but got ~S" c2))))
		   
		   (t (raise-syntax-error
		       "Lexer got unexpected character: ~A (code: ~A)"
		       c (char-code c)))))))))))))


(defun raise-syntax-error (s &rest args)
  ;; Signal SyntaxError if available, otherwise a normal error.
  (let ((s (apply #'format nil s args))
	(s-err (find-class 'SyntaxError nil)))
    (if s-err
	(error 'SyntaxError :args s)
      (error (concatenate 'string "SyntaxError: " s)))))


(defun read-chr-nil ()
  "Returns a character, or NIL on eof/error"
  (funcall *lex-read-char*))

(define-compiler-macro read-chr-nil ()
  `(locally (declare (optimize (speed 3) (safety 1) (debug 0)))
     (funcall *lex-read-char*)))

(defun read-chr-error ()
  "Return a character, or raise a SyntaxError"
  (or (read-chr-nil)
      (raise-syntax-error "Unexpected end of file")))

(defun unread-chr (ch)
  (funcall *lex-unread-char* ch))


(defun char-member (ch list)
  (and ch
       (member ch list :test #'char=)))

(define-compiler-macro char-member (ch list)
  (let ((char '#:char))
    `(let ((,char ,ch))
       (and ,char (member ,char ,list :test #'char=)))))

(defun reserved-word-p (sym)
  (let ((ht (load-time-value
	     
	     #+allegro ;; use a hashtable without values
	     (let ((ht (make-hash-table :test 'eq :values nil)))
	       (dolist (w *reserved-words*) (excl:puthash-key w ht))
	       ht)
	     
	     #-allegro ;; use regular hashtable
	     (let ((ht (make-hash-table :test 'eq)))
	       (dolist (w *reserved-words*) (setf (gethash w ht) t))
	       ht))))
    
    (gethash (the symbol sym) ht)))
  

;; Identifier

(defun identifier-char1-p (c)
  "Is C a character with which an identifier can start?
C must be either a character or NIL."
  (and c
       (or (alpha-char-p c)
	   (char= c #\_))))



(defun identifier-char2-p (c)
  "Can C occur in an identifier as second or later character?
C must be either a character or NIL."
  (and c
       (or (alphanumericp c)
	   (char= c #\_))))

(define-compiler-macro identifier-char2-p (c)
  (let ((ch '#:ch)
	(code '#:code)
	(arr #.(loop with arr = (make-array 128 :element-type 'bit :initial-element 0)
		   for ch-code from 0 below 128
		   for ch = (code-char ch-code)
		   do (setf (aref arr ch-code) (if (or (alphanumericp ch)
						       (char= ch #\_))
						   1 0))
		   finally (return arr))))
    `(let ((,ch ,c))
       (and ,ch
	    (let ((,code (char-code ,ch)))
	      (and (< ,code 128)
		   (= (aref ,arr ,code) 1)))))))


(defconstant +id-history-size+ 15 "Number of previous identifiers to cache.")
(defconstant +id-char-vec-length+ 15
  "Cached vector for identifier, used for looking up identifier in cache
before allocating a vector on its own.")

(defun read-identifier (first-char)
  "Read an identifier (which is possibly a reserved word) and return it as a
symbol. Identifiers start with an underscore or alphabetic character, while
second and later characters must be alphanumeric or underscore."
  
  ;; By caching the last returned identifiers, which are likely to
  ;; recur, a lot less arrays have to be allocated.
  
  (declare (optimize (speed 3) (safety 1) (debug 0)))
  (assert (identifier-char1-p first-char))
  
  (let ((symbol-cache (load-time-value (make-array +id-history-size+)))
	(symbol-name-cache (load-time-value (make-array +id-history-size+)))
	(symbol-cache-replace-ix (load-time-value (list 0)))
	(char-vec     (load-time-value (make-array +id-char-vec-length+ :element-type 'character))))
    
    (macrolet ((cache-symbol (s)
		 (let ((sym '#:sym))
		   `(let ((,sym ,s))
		      (setf (svref symbol-cache (car symbol-cache-replace-ix)) ,sym)
		      (setf (svref symbol-name-cache (car symbol-cache-replace-ix)) (symbol-name ,sym))
		      (when (= (incf (car symbol-cache-replace-ix)) +id-history-size+)
			(setf (car symbol-cache-replace-ix) 0))
		      ,sym))))
			 
      (loop
	  for ch = first-char then (read-chr-nil)
	  for i from 0 below +id-char-vec-length+
	  while (identifier-char2-p ch) do (setf (aref char-vec i) ch)
	  finally
	    (when (and ch (not (identifier-char2-p ch)))
	      (unread-chr ch))
	    (return
	      (if (or (< i +id-char-vec-length+) (null ch))

		  ;; eof or other token following relatively short ID
		  (loop for ci from 0 below +id-history-size+
		      when (loop with cached-sym-str = (svref symbol-name-cache ci)
			       initially (when (/= (length (the string cached-sym-str)) i)
					   (return nil))
			       for j from 0 below i
			       unless (eql (the character (char cached-sym-str j))
					   (the character (schar char-vec j)))
			       return nil
			       finally (return t))
		      do (return (aref symbol-cache ci))
		      finally
			(return (loop with arr = (make-array i :element-type 'character)
				    for j from 0 below i
				    do (setf (schar arr j) (schar char-vec j))
				    finally
				      (return (cache-symbol (or (find-symbol arr #.*package*)
								(intern arr #.*package*)))))))
		
		(loop with arr = (make-array (+ +id-char-vec-length+ 5) 
					     :element-type 'character
					     :adjustable t
					     :fill-pointer +id-char-vec-length+)
		    initially (loop for i from 0 below i
				  do (setf (char arr i) (schar char-vec i)))
		    for ch = (read-chr-nil)
		    while (identifier-char2-p ch) do (vector-push-extend ch arr)
		    finally (when ch (unread-chr ch))
			    (return
			      (loop for ci from 0 below +id-history-size+
				  when (string= (svref symbol-cache ci) arr)
				  return (svref symbol-cache ci)
				  finally
				    (return (cache-symbol (or (find-symbol arr #.*package*)
							      (intern arr #.*package*)))))))))))))

#+(or) ;; Equivalent, but a bit slower, original code. Allocates an array for every identifier.
(defun read-identifier (first-char)
  "Returns the identifier read as string. ~@
   Identifiers start start with an underscore or alphabetic character; ~@
   second and further characters must be alphanumeric or underscore."

  (assert (identifier-char1-p first-char))
  (let ((res (load-time-value
	      (make-array 6 :element-type 'character
			  :adjustable t
			  :fill-pointer 0))))
    (setf (fill-pointer res) 0)
    (vector-push-extend first-char res)
    
    (loop
	for c = (read-chr-nil)
	while (identifier-char2-p c)
	do (vector-push-extend c res)
	finally (when c (unread-chr c)))
    
    (or (find-symbol res #.*package*)
	(intern (simple-string-from-vec res) #.*package*))))


;; String

(defun simple-string-from-vec (vec)
  (make-array (length vec)
	      :element-type 'character
	      :initial-contents vec))

(defun read-string (first-char &key unicode raw)
  "Returns string as a string"
  ;; Rules:
  ;; <http://meta.kabel.utwente.nl/specs/Python-Docs-2.3.3/ref/strings.html>

  (assert (char-member first-char '( #\' #\" )))
  
  (when raw
    ;; Include escapes literally in the resulting string.
      
    (loop with ch = (read-chr-error)
	with res = (load-time-value
		    (make-array 10 :element-type 'character
				:adjustable t :fill-pointer 0))
	with num-bs = 0
	initially (setf (fill-pointer res) 0)
		    
	do (case ch
	     (#\\  (progn (vector-push-extend ch res)
			  (incf num-bs)))
	       
	     (#\u  (if (and unicode
			    (oddp num-bs))
			 
		       (loop for i below 4
			   with code = 0
			   with ch = (read-chr-error)
			   do (setf code (+ (* code 16)
					    (or (digit-char-p ch 16)
						(raise-syntax-error
						 "Non-hex digit in \"\u...\": ~S" ch)))
				    ch (read-chr-error))
			   finally (vector-push-extend (code-char code) res))
		       
		     (vector-push-extend #\u res))
		   (setf num-bs 0))
	       
	     ((#\' #\") (cond ((and (char= ch first-char) (> num-bs 0))         
			       (vector-push-extend ch res)
			       (setf num-bs 0))
			      
			      ((char= ch first-char)
			       (return-from read-string (simple-string-from-vec res)))
			      (t
			       (vector-push-extend ch res)
			       (setf num-bs 0))))
	     
	     (t (vector-push-extend ch res)
		(setf num-bs 0)))
	     
	   (setf ch (read-chr-error))))
    
  (assert (not raw))
    
  (let* ((second (read-chr-error))
	 (third (read-chr-nil)))
    (cond 
     ((char= first-char second third)      ;; """ or ''': a probably long multi-line string
      (loop
	  with res = (load-time-value 
		      (make-array 50 :element-type 'character :adjustable t :fill-pointer 0))
	  with x = (read-chr-error) and y = (read-chr-error) and z = (read-chr-error)
	  initially (setf (fill-pointer res) 0)
		      
	  until (char= first-char z y x)
	  do (vector-push-extend (shiftf x y z (read-chr-error)) res)
	       
	  finally (return-from read-string (simple-string-from-vec res))))
       
     ((char= first-char second)  ;; ""/'' but not """/''' --> empty string
      (when third
	(unread-chr third))
      (return-from read-string ""))
       
     (t ;; Non-empty string with one starting quote, possibly containing escapes
      (unless third
	(raise-syntax-error "Quoted string not finished"))
      (let ((res (load-time-value
		  (make-array 30 :element-type 'character :adjustable t :fill-pointer 0)))
	    (c third)
	    (prev-backslash (char= second #\\ )))
	(setf (fill-pointer res) 0)
	(unless (char= second #\\)
	  (vector-push-extend second res))
	(loop 
	  (cond
	   (prev-backslash
	    (case c 
	      (#\\ (vector-push-extend #\\ res))
	      (#\' (vector-push-extend #\' res))
	      (#\" (vector-push-extend #\" res))
	      (#\a (vector-push-extend #\Bell res))
	      (#\b (vector-push-extend #\Backspace res))
	      (#\f (vector-push-extend #\Page res))
	      (#\n (vector-push-extend #\Newline res))
	      (#\Newline )  ;; ignore this newline; quoted string continues on next line
	      (#\r (vector-push-extend #\Return res))
	      (#\t (vector-push-extend #\Tab res))
	      (#\v (vector-push-extend #\VT  res))
		
	      (#\N
	       (if unicode  ;; unicode char by name: u"\N{latin capital letter l with stroke}"
		     
		   (let ((ch2 (read-chr-error))) 
		     (unless (char= ch2 #\{)
		       (raise-syntax-error
			"In Unicode string: \N{...} expected, but got ~S after \N" ch2))
		     (loop with ch = (read-chr-error)
			 with vec = (make-array 10 :element-type 'character
						:adjustable t :fill-pointer 0)
			 while (char/= ch #\}) do
			   (vector-push-extend (if (char= ch #\space) #\_ ch) vec)
			   (setf ch (read-chr-error))
			 finally
			   #+(or)(break "Charname: ~S" vec)
			   (vector-push-extend (name-char vec) res)))
		   
		 (progn (warn "Unicode escape  \\N{..}  found in non-unicode string")
			(vector-push-extend #\\ res)
			(vector-push-extend #\N res))))
		
	      ((#\u #\U) (if unicode
			       
			     (loop for i below (if (char= c #\u) 4 8) ;; \uf7d6 \U12345678
				 with code = 0
				 with ch
				 do (setf ch   (read-chr-error)
					  code (+ (* 16 code) 
						  (or (digit-char-p ch 16)
						      (raise-syntax-error
						       "Non-hex digit in \"\~A...\": ~S" c ch))))
				 finally (vector-push-extend (code-char code) res))
			     
			   (progn (warn "Unicode escape \\~A... found in non-unicode string" c)
				  (vector-push-extend #\\ res)
				  (vector-push-extend c res))))
	        
	      ((#\0 #\1 #\2 #\3 #\4 #\5 #\6 #\7)  ;; char code: up to three octal digits
	       (loop with code = 0
		   with x = c
		   for num from 1
		   while (and (<= num 3) (digit-char-p x 8))
		   do (setf code (+ (* code 8) (digit-char-p x 8))
			    x (read-chr-error))
		   finally (unread-chr x)
			   (vector-push-extend (code-char code) res)))
	      
	      
	      (#\x (let* ((a (read-chr-error)) ;; char code: up to two hex digits
			  (b (read-chr-error)))
		     
		     (cond ((not (digit-char-p a 16))
			    (raise-syntax-error "Non-hex digit found in \x..: ~S" a))
			   
			   ((digit-char-p b 16)
			    (vector-push-extend (code-char (+ (* 16 (digit-char-p a 16)) 
							      (digit-char-p b 16)))
						res))
			   
			   (t (vector-push-extend (digit-char-p a 16) res)
			      (unread-chr b)))))
	        
	      (t 
	       ;; Backslash is not used for escaping: collect both the backslash
	       ;; itself and the character just read.
	       (vector-push-extend #\\ res)
	       (vector-push-extend c res)))
		
	    (setf prev-backslash nil))
	       
	   ((char= c #\\)
	    (setf prev-backslash t))
	   
	   ((char= c first-char) ;; end quote of literal string
	    (return-from read-string (simple-string-from-vec res)))
	       
	   (t 
	    (vector-push-extend c res)))
	      
	  (setf c (read-chr-error))))))))


;; Number

;; integers:     input  -> base-10 val  system used
;;                 11           11         10 (decimal)
;;                011            9          8 (octal)
;;               0x11           17         16 (hexadecimal)
;;
;; integers with exponent:
;;       11e3 = 011e3 = 11E3 = 11e+3 == 11E+3 = 11000.0 (a float)
;;       11e-3 = 0.011 (approx)
;;       0x11e3 = regular hex 4579
;;
;; floats:       input  -> base-10 val  system used
;;                11.3         11.3        10
;;               011.3         11.3        10    ! (exp: error)
;;              0x11.3           *syntax error*
;;
;; floats with exponent:
;;        011.3e3 = 11.3e3 = 011.3e+3 = 11.3e+3 = 11300
;;        011.3e-3 = 11.3e-3 = 11300
;;
;; imag ints:    input  -> base-10 val  system used
;;                11j          11j         10
;;               011j          11j         10    ! (exp: 9j)
;;              0x11j           *syntax error*   ! (exp: 17j)
;;
;; imag ints with exponent:
;;         1e3j = 1000j etc.
;;
;; imag floats:  input  -> base-10 val  system used
;;               11.3j         11.3j       10
;;              011.3j         11.3j       10   ! (exp: error)
;;             0x11.3j          *syntax error*
;;
;; imag floats with exp:
;;    1.0e-3j -> 0.001j etc.
;;
;; Integers (dec, oct, hex) may have the suffix `l' or `L', meaning
;; `long', though the difference between regular and long integers
;; has mostly ceased to exist (operations on regular integers that
;; return an integer in the range of long integers, implicitly
;; convert the result to a long). We ignore any difference between
;; regular and long integers.

(defun read-number (&optional (first-char (read-chr-error)))
  (assert (digit-char-p first-char 10))
  (let ((base 10)
	(res 0))
	
    (flet ((read-int (&optional (res 0))
	     
	     ;;#+(or)
	     ;; This version calls the Lisp reader on the string with digits
	     (loop with vec = (make-array 5 :adjustable t :fill-pointer 0
					  :element-type 'character)
		 with ch = (read-chr-nil)
			   
		 initially 
		 (when (/= 0 res)
		   (vector-push-extend (code-char (+ (char-code #\0) res)) vec))
			  
		 while (and ch (digit-char-p ch base))
		 do (vector-push-extend ch vec)
		    (setf ch (read-chr-nil))
		    
		 finally (when ch 
			   (unread-chr ch))
			 (let ((*read-base* base))
			   (return (read-from-string vec))))
	     
	     #+(or)
	     ;; Equivalent code, but not calling the lisp reader, so
	     ;; slightly slower than the above.
	     (loop with ch = (read-chr-nil)
			while (and ch (digit-char-p ch base))
			do (setf res (+ (* res base) (digit-char-p ch base))
				 ch (read-chr-nil))
			finally (when ch 
				  (unread-chr ch))
				(return res))))
	  
      (if (char= first-char #\0)

	  (let ((second (read-chr-nil)))
	    (setf res (cond ((null second) 0) ;; eof
			     
			    ((char-member second '(#\x #\X))
			     (setf base 16)
			     (read-int))
			    
			    ((digit-char-p second 8)
			     (setf base 8)
			     (read-int (digit-char-p second 8)))
			    
			    ((char= second #\.)
			     (unread-chr second)
			     0)
			    
			    ((digit-char-p second 10) 
			     (read-int (digit-char-p second 10)))
			    
			    ((char-member second '(#\j #\J))  (complex 0 0))
			    ((char-member second '(#\l #\L))  0)
			    
			    (t (unread-chr second)
			       0)))) ;; non-number, like `]' in `x[0]'
	
	(setf res (read-int (digit-char-p first-char 10))))
      
      (let ((has-frac nil) (has-exp nil))
	
	(when (= base 10)
	  (let ((dot? (read-chr-nil)))
	    (if (and dot? (char= dot? #\.))
		
		(progn
		  (setf has-frac t)
		  (incf res
			(loop
			    with ch = (read-chr-nil)
			    with lst = ()
			    while (and ch (digit-char-p ch 10))
			    do (push ch lst)
			       (setf ch (read-chr-nil))
			       
			    finally (push #\L lst) ;; use `long-float' (CPython uses 32-bit C `long')
				    (push #\0 lst)
				    (setf lst (nreverse lst))
				    (push #\. lst)
				    (push #\0 lst)
				    (unread-chr ch)
				    (return (read-from-string 
					     (make-array (length lst)
							 :initial-contents lst
							 :element-type 'character))))))
		      
	      (when dot? (unread-chr dot?)))))
	
	;; exponent marker
	(when (= base 10)
	  (let ((ch (read-chr-nil)))
	    (if (char-member ch '(#\e #\E))
		
		(progn
		  (setf has-exp t)
		  (let ((ch2 (read-chr-error))
			(exp 0)
			(minus nil)
			(got-num nil))
		  
		    (cond
		     ((char= ch2 #\+))
		     ((char= ch2 #\-)       (setf minus t))
		     ((digit-char-p ch2 10) (setf exp (digit-char-p ch2 10)
						  got-num t))
		     (t (raise-syntax-error 
			 "Exponent for literal number invalid: ~A ~A" ch ch2)))
		  
		    (unless got-num
		      (let ((ch3 (read-chr-error)))
			(if (digit-char-p ch3 10)
			    (setf exp (+ (* 10 exp) (digit-char-p ch3 10)))
			  (raise-syntax-error
			   "Exponent for literal number invalid: ~A ~A ~A" ch ch2 ch3))))
		    
		    (loop with ch
			while (and (setf ch (read-chr-nil))
				   (digit-char-p ch 10))
			do (setf exp (+ (* 10 exp) (digit-char-p ch 10)))
			finally (when ch (unread-chr ch)))
		  
		    (when minus
		      (setf exp (* -1 exp)))
		  
		    (setf res (* res (expt 10 exp)))))
	      
	      (when ch
		(unread-chr ch)))))
	
	;; CPython allows `j', decimal, not for hex (SyntaxError) or
	;; octal (becomes decimal!!?)  and allows 'L' for decimal,
	;; hex, octal
	
	
	;; suffix `L' for `long integer'
	(unless (or has-frac has-exp)
	  (let ((ch (read-chr-nil)))
	    (if (and ch 
		     (not (char-member ch '(#\l #\L))))
		(unread-chr ch))))
		
	;; suffix `j' means imaginary
	(let ((ch (read-chr-nil)))
	  (if (char-member ch '(#\j #\J))
	      (setf res (complex 0 res))
	    (when ch (unread-chr ch)))))
		
      res)))
		

;;; Punctuation

(defun read-punctuation (c1)
  "Returns puncutation as symbol."
  (assert (or (punct-char1-p c1)
	      (punct-char-not-punct-char1-p c1)))
  (let ((c2 (read-chr-nil)))
    (if (punct-char2-p c1 c2)
	
	(let ((c3 (read-chr-nil)))
	  (if (punct-char3-p c1 c2 c3)

	      ;; 3 chars
	      (ecase c1
		(#\* '**=)
		(#\< '<<=)
		(#\> '>>=)
		(#\/ '//=))
		    
	    ;; 2 chars
	    (progn (when c3 
		     (unread-chr c3))
		   (ecase c2
		     (#\= (ecase c1
			    (#\= '==) (#\> '>=) (#\< '<=) (#\+ '+=) (#\- '-=)
			    (#\* '*=) (#\^ '^=) (#\! '!=) (#\/ '/=) (#\| '\|=)
			    (#\% '%=) (#\& '&=)))
		     (#\> (ecase c1
			    (#\< '<>)
			    (#\> '>>)))
		     (#\< (ecase c1
			    (#\< '<<)))
		     (#\/ (ecase c1
			    (#\/ '//)))
		     (#\* (ecase c1
			    (#\* '**)))))))
		     
	    
      ;; 1 char, or two of three dots
      
      (if (and c2 (char= #\. c1 c2))
	  
	  (if (char= (read-chr-error) #\.)
	      '|...|
	    (raise-syntax-error "Dots `..' may only occur as triple: `...'"))
	
	(if (punct-char1-p c1)
	    
	    (progn (when c2 (unread-chr c2))
		   (ecase c1
		     (#\. '|.|) (#\= '|=|) (#\+ '|+|) (#\[ '|[|) (#\] '|]|) (#\( '|(|)
		     (#\) '|)|) (#\< '|<|) (#\> '|>|) (#\{ '|{|) (#\} '|}|) (#\- '|-|)
		     (#\` '|`|) (#\, '|,|) (#\: '|:|) (#\^ '|^|) (#\& '|&|) (#\| '|\||)
		     (#\% '|%|) (#\* '|*|) (#\/ '|/|) (#\~ '|~|) (#\@ '|@|)))
		   
	  (raise-syntax-error
	   "Character `!' may only occur as in `!=', not standalone"))))))


(defun punct-char1-p (c)
  ;; table-based lookup is way faster
  (let ((arr (load-time-value
	      (loop
		  with arr = (make-array 128 :element-type 'bit :initial-element 0)
		  for ch across "`=[]()<>{}.,:|^&%+-*/~;@"
		  do (setf (aref arr (char-code ch)) 1)
		  finally (return arr)))))
    (let ((cc (char-code c)))
      (and (< cc 128) 
	   (= (aref arr cc) 1)))))

(defun punct-char-not-punct-char1-p (c)
  "Punctuation  !  may only occur in the form  !=  "
  (and c 
       (char= c #\! )))

(defun punct-char2-p (c1 c2)
  "Recognizes: // << >>  <> !=  <= >=
               == += -= *= /= %=  ^= |= &= ** **= <<= >>= "
  (and c1 c2
       (or (and (char= c2 #\= )
		(char-member c1 '( #\+ #\- #\* #\/ #\%  #\^ #\&
				  #\| #\! #\= #\< #\> )))
	   (and (char= c1 c2)
		(char-member c1 '( #\* #\< #\> #\/ #\< #\> )))
	   (and (char= c1 #\< )
		(char= c2 #\> )))))

(defun punct-char3-p (c1 c2 c3)
  "Recognizes:  **= <<= >>= //="
  (and c1 c2 c3
       (char= c3 #\= )
       (char= c1 c2)
       (char-member c1 '( #\* #\< #\> #\/ ))))


;;; Whitespace

(defun read-whitespace ()
  "Reads all whitespace and comments, until first non-whitespace character.

If Newline was found inside whitespace, values returned are (t N) where N
is the amount of whitespace after the Newline before the first
non-whitespace character (in other words, the indentation of the first
non-whitespace character) measured in spaces, where each Tab is equivalent
to *tab-width-spaces* spaces - so N >= 0.

If no Newline was encountered before a non-whitespace character, or if EOF
is encountered, NIL is returned."
  
  (loop
      with found-newline = nil and n = 0
      for c = (read-chr-nil)
      do (case c
	   ((nil)                  (return-from read-whitespace nil))
	   
	   ((#\Newline #\Return)   (setf found-newline t
					 n 0))
	   
	   (#\Space                (incf n))
	   
	   (#\Tab                  (incf n *tab-width-spaces*))
	   
	   (#\#                    (progn (read-comment-line c)
					  (setf found-newline t
						n 0)))
	   
	   (t                      (unread-chr c)
				   (return-from read-whitespace
				     (if found-newline (values t n) nil))))))

(defun read-comment-line (c)
  "Read until the end of the line, leaving the last #\Newline in the source."
  (assert (char= c #\#))
  (loop
      for c = (read-chr-nil) while (and c (char/= c #\Newline))
      finally (when c (unread-chr c))))


;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Lexer usage

(defun parse-python-with-lexer (&rest lex-options)
  (let* ((lexer (apply #'make-py-lexer lex-options))
	 (grammar (make-instance 'python-grammar :lexer lexer)))
    (parse grammar)))

(defgeneric parse-python-file (source)
  (:method ((s stream))
	   (parse-python-with-lexer :read-chr   (lambda ()
						  (declare (optimize (speed 3) (safety 1) (debug 0)))
						  (read-char s nil nil))
				    :unread-chr (lambda (c)
						  (declare (optimize (speed 3) (safety 1) (debug 0)))
						  (unread-char c s))))
  (:method (filename)
	   (with-open-file (f filename :direction :input)
	     (parse-python-file f))))

(defmethod parse-python-string ((s string))
  (let ((next-i 0)
	(max-i (length s)))
    (parse-python-with-lexer
     :read-chr (lambda ()
		  (when (< next-i max-i)
		    (prog1 (char s next-i) (incf next-i))))
     
     :unread-chr (lambda (c)
		    (assert (and c (> next-i 0) (char= c (char s (1- next-i)))))
		    (decf next-i)))))

    
#+(or)
(defun parse-python (&optional (*standard-input* *standard-input*))
  (let* ((lexer (make-py-lexer))
	 (grammar (make-instance 'python-grammar :lexer lexer))
	 (*print-level* nil)
	 (*print-pretty* t))
    (parse grammar)))

#+(or)
(defun parse-python-string (string)
  (with-input-from-string (stream string)
    (parse-python stream)))

#+(or)
(defun parse-python-string-literal (string)
  (second (py-eval (parse-python-string string))))

#+(or)
(defun file->ast (fname)
  (parse-python-string (read-file fname)))
