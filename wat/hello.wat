(module
  ;; fd_write(file_descriptor, *iovs, iovs_len, nwritten) -> i32: number of bytes written
  (import "wasi_snapshot_preview1" "fd_write" (func $fd_write (param i32 i32 i32 i32) (result i32)))

  (memory 1)
  (export "memory" (memory 0))

  (data (i32.const 8) "Hello, world!\n")

  (func $main (export "_start")
    (i32.store (i32.const 0) (i32.const 8))   ;; *iovs: memory adderess
    (i32.store (i32.const 4) (i32.const 14))  ;; iovs_len: length of iovs
    
    (call $fd_write
      (i32.const 1) ;; file_descriptor: 1 = stdout
      (i32.const 0) ;; *iovs: memory address of the iov array, which is stored at memory offset 0
      (i32.const 4) ;; iovs_len: length of io vectors, 1 string in this case
      (i32.const 24)) ;; nwritten: A memory address to store the number of bytes written
    drop
  )
)