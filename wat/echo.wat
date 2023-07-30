(module
  ;; fd_write(file_descriptor, *iovs, iovs_len, nwritten) -> i32: number of bytes written
  (import "wasi_snapshot_preview1" "fd_write" (func $fd_write (param i32 i32 i32 i32) (result i32)))
  ;; args_sizes_get(argc, argv_buf_size) -> i32: number of bytes written
  (import "wasi_snapshot_preview1" "args_sizes_get" (func $args_sizes_get (param i32 i32) (result i32)))
  ;; args_get(argv, argv_buf) -> i32: number of bytes written
  (import "wasi_snapshot_preview1" "args_get" (func $args_get (param i32 i32) (result i32)))

  (memory 1)
  (export "memory" (memory 0))

  (data (i32.const 8) "usage: echo.wasm <arg>\00") ;; 23 bytes

  (func $has_args (result i32)
    ;; result: コマンドライン引数ありなら 1、なければ 0

    (call $args_sizes_get
      (i32.const 0) ;; argc: size (u32) コマンドライン引数の数 -> [0:3] へ格納
      (i32.const 4)) ;; argv_buf_size: size (32) コマンドライン引数のデータ長 -> [4:7] へ格納
    drop

    ;; argc > 1 ならばコマンドライン引数あり（i32.ge_u ではダメ、理由はコマンド名自身が argv[0] に入るため）
    (i32.gt_u (i32.load (i32.const 0)) (i32.const 1))
  )

  (func $get_first_arg (param $n_args i32) (param $argv_buf_ptr i32) (result i32)
    ;; $ n_args: コマンドライン引数の数
    ;; $ argv_buf_ptr: コマンドライン引数のアドレス配列へのポインタ

    (call $args_get
      (local.get $argv_buf_ptr) ;; argv: コマンドライン引数のアドレス配列、ポインタで指定する
      (i32.add
        (local.get $argv_buf_ptr)
        (i32.mul (local.get $n_args) (i32.const 4))
      )) ;; argv_buf: コマンドライン引数のデータ実体を格納するアドレス、argv と衝突しないよう argv + (n_args * 4) に配置する
    drop

    ;; 1つ目のコマンドライン引数のデータ実体が格納されているアドレスを load -> スタックへ積む
    (i32.load (i32.add (local.get $argv_buf_ptr) (i32.const 4)))
  )

  (func $str_len (param $str_ptr i32) (result i32)
    (local $n i32)
    (local.set $n (i32.const 0))

    (loop $next
      (if (i32.eqz (i32.load8_u (i32.add (local.get $str_ptr) (local.get $n))))
        (then
          (return (local.get $n)))
        (else nop)
      )
      (local.set $n (i32.add (local.get $n) (i32.const 1)))
      (br $next)
    )
    (unreachable)
  )

  (func $main (export "_start")
    (local $errno i32)
    (local $output_ptr i32) ;; 出力文字列のアドレス
    (local $output_len i32) ;; 出力文字列長

    ;; デフォルトの出力文字列に usage を設定
    (local.set $output_ptr (i32.const 8))
    (local.set $output_len (i32.const 23))

    (if (call $has_args)
      (then
        (local.set
          $output_ptr
          (call $get_first_arg (i32.load (i32.const 0)) (i32.const 32)))
        (local.set $output_len (call $str_len (local.get $output_ptr)))
      )
      (else nop)
    )

    (i32.store (i32.const 0) (local.get $output_ptr))  ;; *iovs: io vector の先頭アドレス
    (i32.store (i32.const 4) (local.get $output_len))  ;; iovs_len: io vector のデータ実体のバイト長
    
    (local.set $errno
      (call $fd_write
        (i32.const 1) ;; file_descriptor: 1 = stdout
        (i32.const 0) ;; *iovs: io vector のアドレス
        (i32.const 1) ;; iovs_len: io vector の要素数
        (i32.const 0))) ;; nwritten: 出力文字列バイト数を格納するアドレス
  )
)