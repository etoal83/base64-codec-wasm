(module
  ;; fd_write(file_descriptor, *iovs, iovs_len, nwritten) -> i32: number of bytes written
  (import "wasi_snapshot_preview1" "fd_write" (func $fd_write (param i32 i32 i32 i32) (result i32)))
  ;; args_sizes_get(argc, argv_buf_size) -> i32: number of bytes written
  (import "wasi_snapshot_preview1" "args_sizes_get" (func $args_sizes_get (param i32 i32) (result i32)))
  ;; args_get(argv, argv_buf) -> i32: number of bytes written
  (import "wasi_snapshot_preview1" "args_get" (func $args_get (param i32 i32) (result i32)))

  (memory 1)
  (export "memory" (memory 0))

  ;; MEMORY LAYOUT
  ;; [0:3]  argc: size (u32) コマンドライン引数の数
  ;; [4:7]  argv_buf_size: size (u32) コマンドライン引数のデータ長
  ;; [8:72] base64_chars: base64 エンコード用の文字列
  ;; [76:1023] argv, argv_buf: コマンドライン引数のアドレス配列とデータ実体
  ;; [1024:] encoded_str_buf: エンコード後の文字列を格納するバッファ

  (data (i32.const 8) "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
  (data (i32.const 1024) "                                                                                                                                ")

  (func $has_args (result i32)
    ;; コマンドライン引数の数 argc とデータ長 argv_buf_size をメモリに格納し、引数が与えられたかどうかを返す
    ;; result: コマンドライン引数ありなら 1、なければ 0

    (call $args_sizes_get
      (i32.const 0) ;; argc: size (u32) コマンドライン引数の数 -> [0:3] へ格納
      (i32.const 4)) ;; argv_buf_size: size (u32) コマンドライン引数のデータ長 -> [4:7] へ格納
    drop

    ;; argc > 1 ならばコマンドライン引数あり（i32.ge_u ではダメ、理由はコマンド名自身が argv[0] に入るため）
    (i32.gt_u (i32.load (i32.const 0)) (i32.const 1))
  )

  (func $get_first_arg (param $n_args i32) (param $argv_ptr i32) (result i32)
    ;; コマンドライン引数情報をメモリに格納し、1つ目のコマンドライン引数のデータ実体のアドレスを返す
    ;; $ n_args: コマンドライン引数の数 (given)、$has_args で格納した argc を指定する
    ;; $ argv_ptr: コマンドライン引数のアドレス配列を格納するアドレス (voluntary)

    ;; e.g. `wasmer b64encode.wasm foo bar ... baz` というコマンドで呼び出された時
    ;; | argv[0] | argv[1] | ... | argv[n] | argv_buf
    ;; | 4 bytes | 4 bytes | ... | 4 bytes | string
    ;; |   u32   |   u32   | ... |   u32   | "b64encode.wasm\0foo\0bar\0...\0baz"
    ;; ^                                   ^                  ^
    ;;(1)                                 (2)                (3)
    ;;
    ;; (1) $args_get 第1引数 ← このアドレスをどこにしたいか、$get_first_arg 呼び出し時に argv_ptr で渡す
    ;; (2) $args_get 第2引数 ← argv と衝突しないよう argv + (n_args * 4) に置くようにする
    ;; (3) この関数が返すアドレス (u32)
    (call $args_get
      (local.get $argv_ptr) ;; (1) → ここへコマンドライン引数のアドレス配列を格納
      (i32.add
        (local.get $argv_ptr)
        (i32.mul (local.get $n_args) (i32.const 4)) ;; argv_buf: コマンドライン引数のデータ実体を格納するアドレス
      ))
    drop

    ;; 1つ目のコマンドライン引数のデータ実体が格納されているアドレスを load = (3) -> スタックへ積む
    (i32.load (i32.add (local.get $argv_ptr) (i32.const 4)))
  )

  (func $str_len (param $str_ptr i32) (result i32)
    ;; 与えられた文字列の長さ（バイト長）を返す
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

  (func $set_encoded_string (param $src_ptr i32) (param $src_len i32) (result i32)
    ;; 与えられた文字列を base64 エンコードしてメモリに格納し、エンコード後の文字列の長さ（バイト長）を返す

    (local $n i32)    ;; $n: 3 文字単位で入力を処理するためのカウンタ
    ;; base64 エンコード済み出力文字数 = 4k + frac
    (local $k i32)    ;; $k: 4 文字単位で出力を処理するためのカウンタ
    (local $frac i32) ;; $frac: 4 文字単位の出力の何文字目かを示すカウンタ
    (local $rem i32)  ;; $rem: 残りの未処理の入力文字数
    (local $plain_quadbyte i32) ;; $plain_quadbyte: 4バイト分 = 3文字分+αの入力文字バイトを格納する変数

    (local.set $rem (local.get $src_len))
    (local.set $k (i32.const 0))
    (local.set $n (i32.const 0))

    (loop $next_src_triplet (block $break
      (br_if $break (i32.eqz (local.get $rem)))

      ;; 約 4バイト分の入力文字を $plain_quadbyte へ格納（使うのは入力 3 文字分のみ、残り1文字は次の load で扱う）
      (local.set $plain_quadbyte (call $reorder_i32_byte (i32.load (i32.add (local.get $src_ptr) (local.get $n)))))

      ;; 1 文字目: bit range [26:31]
      (local.set $frac (i32.const 0)) ;; $frac -> 0
      (call $store_encoded_kfrac (local.get $plain_quadbyte) (local.get $k) (local.get $frac) (i32.const 0xfc000000))

      ;; 2 文字目: bit range [20:25]
      (local.set $frac (i32.add (local.get $frac) (i32.const 1))) ;; $frac -> 1
      (call $store_encoded_kfrac (local.get $plain_quadbyte) (local.get $k) (local.get $frac) (i32.const 0x3f00000))
      (if (i32.eq (local.get $rem) (i32.const 1))
        (then
          (call $pad_equal_kfrac (local.get $k) (i32.const 2))
          (call $pad_equal_kfrac (local.get $k) (i32.const 3))
          (local.set $k (i32.add (local.get $k) (i32.const 1)))
          (br $break))
        (else nop))

      ;; 3 文字目: bit range [14:19]
      (local.set $frac (i32.add (local.get $frac) (i32.const 1))) ;; $frac -> 2
      (call $store_encoded_kfrac (local.get $plain_quadbyte) (local.get $k) (local.get $frac) (i32.const 0xfc000))
      (if (i32.eq (local.get $rem) (i32.const 2))
        (then
          (call $pad_equal_kfrac (local.get $k) (i32.const 3))
          (local.set $k (i32.add (local.get $k) (i32.const 1)))
          (br $break))
        (else nop))

      ;; 4 文字目: bit range [8:13]
      (local.set $frac (i32.add (local.get $frac) (i32.const 1))) ;; $frac -> 3
      (call $store_encoded_kfrac (local.get $plain_quadbyte) (local.get $k) (local.get $frac) (i32.const 0x3f00))

      ;; インクリメント／デクリメント
      (local.set $n (i32.add (local.get $n) (i32.const 3)))
      (local.set $k (i32.add (local.get $k) (i32.const 1)))
      (local.set $rem (i32.sub (local.get $rem) (i32.const 3)))
      (br $next_src_triplet)
    ))

    (i32.add (i32.mul (local.get $k) (i32.const 4)) (local.get $frac))
  )

  (func $reorder_i32_byte (param $in i32) (result i32)
    ;; 与えられた 4 バイトの入力を、バイト順を逆にして返す
    ;; （※ WebAssembly のバイトオーダーはリトルエンディアンなため）
    ;; e.g. "\0A\0B\0C\0D" --(i32.load)--> 0x0D0C0B0A --($reorder_i32_byte)--> 0x0A0B0C0D
    (i32.or
      (i32.or
        (i32.shr_u (i32.and (local.get $in) (i32.const 0xff000000)) (i32.const 24))
        (i32.shr_u (i32.and (local.get $in) (i32.const 0xff0000)) (i32.const 8))
      )
      (i32.or
        (i32.shl (i32.and (local.get $in) (i32.const 0xff00)) (i32.const 8))
        (i32.shl (i32.and (local.get $in) (i32.const 0xff)) (i32.const 24))
      )
    )
  )

  (func $store_encoded_kfrac (param $quadbyte i32) (param $k i32) (param $frac i32) (param $bit_mask i32)
    ;; 4k + frac 文字目の base64 エンコード文字を格納する
    (i32.store8
      ;; エンコードされた文字の格納先アドレス
      (i32.add
        (i32.const 1024)
        (i32.add (i32.mul (local.get $k) (i32.const 4)) (local.get $frac)))
      ;; base64_chars から文字を取得。 $quadbyte の対応する 6 bit を浮いている桁数分右ビットシフトしてインデックスとする
      (i32.load8_u offset=8
        (i32.shr_u
          (i32.and
            (local.get $quadbyte)
            (local.get $bit_mask))
          (i32.ctz (local.get $bit_mask)))))
  )

  (func $pad_equal_kfrac (param $k i32) (param $frac i32)
    ;; 4k + frac 文字目の base64 エンコード文字に `=` を格納する
    (i32.store8
      ;; エンコードされた文字の格納先アドレス
      (i32.add
        (i32.const 1024)
        (i32.add (i32.mul (local.get $k) (i32.const 4)) (local.get $frac)))
      ;; base64_chars から `=` の文字を取得
      (i32.load8_u offset=8 (i32.const 64)))
  )

  (func $main (export "_start")
    (local $errno i32)
    (local $first_arg_ptr i32) ;; 1つ目のコマンドライン引数のアドレス
    (local $first_arg_len i32) ;; 1つ目のコマンドライン引数の長さ
    (local $output_ptr i32) ;; 出力文字列のアドレス
    (local $output_len i32) ;; 出力文字列長

    ;; デフォルトの出力文字列に base64_chars を設定
    (local.set $output_ptr (i32.const 8))
    (local.set $output_len (i32.const 64))

    (if (call $has_args)
      (then
        (local.set $first_arg_ptr (call $get_first_arg (i32.load (i32.const 0)) (i32.const 76)))
        (local.set $first_arg_len (call $str_len (local.get $first_arg_ptr)))
        (i64.store (i32.add (local.get $first_arg_ptr) (local.get $first_arg_len)) (i64.const 0))

        (local.set $output_ptr (i32.const 1024))
        (local.set $output_len (call $set_encoded_string (local.get $first_arg_ptr) (local.get $first_arg_len)))
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