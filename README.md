# OpenRestyはどれくらいお気軽なウェブアプリ環境なのか。

**まとめの後に追記を追加。**

OpenResty は Nginx をダイナミック・リバースプロキシーサーバに仕立て上げたり、テンプレートエンジンを仕込んでバックエンドの JSON API サーバにリクエストしたレスポンスデータを元にレンダリングして返したり、と色々便利に使えるお気楽ウェブアプリ環境なのだけれど、画像処理系のCPUに負荷のかかりそうなものでもお気軽にいけるのかなとふと疑問に思ったの実験してみる。

OpenResty や LuaRocks のインストールは homebrew でさっくり入るし、windows はパソコン初心者並の知識しかないのではしょる事にして、とりあえずテーマを決める。

「nginx 画像処理」でググってみると「簡単！リアルタイム画像変換をNginxだけで行う方法 | cloudrop」ってのが一番上にあったり「S3をバックエンドにngx_small_lightで画像を動的に ...」なんてサイトがあったり、気軽に出来そうな感じだし良いかもってことでこれいってみよ。

Note: ちなみに、作るー＞文章を書くって流れだと確実に面倒に思って書かなくなってしまうので、書きながら作っていくことにする。


## OpenRestyでイメージフィルタ｜下準備

とりあえず以下のようなディレクトリ構成にする。

```
./img-server/
├── conf
│   ├── mime.types
│   └── nginx.conf
├── logs
│   ├── access.log
│   └── error.log
├── luahooks
│   ├── image.lua
│   └── init.lua
└── public
    └── images
        └── index.html
```

それから、その辺にころがってるファイルを元にしてテキトーに nginx.conf を以下のようにでっち上げる。

```nginx
worker_processes    1;
events {
    worker_connections  1024;
    accept_mutex_delay  100ms;
}

http {
    sendfile            on;
    tcp_nopush          on;
    include             mime.types;
    default_type        text/html;
    index               index.html;
    
    #
    # log settings
    #
    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';
    access_log  logs/access.log main;
    
    # 
    # lua global settings
    #
    lua_package_path        '$prefix/luahooks/?.lua;;';
    lua_check_client_abort  on;
    lua_code_cache          on;
    
    #
    # initialize script
    #
    init_by_lua_file        luahooks/init.lua;
    
    #
    # public
    #
    server {
        listen      1080;
        root        public/images;
        
        #
        # content handler
        #
        location / {
            content_by_lua_file         luahooks/image.lua;
        }
    }
}

```

これで初期化フェーズは `luahooks/image.lua` コンテントフェーズを `luahooks/image.lua` でフックすることにする。けど、後で都合が悪くなったら変えるかもしれない。それじゃ、まずは動作確認ってことで `luahooks/image.lua` の中身を以下のように書いて定番の「hello world」を表示してみる。

```lua
ngx.say('hello world');
```

それからプリフィックスを指定して `/path/to/command/nginx -p /path/to/img-server` で nginx を起動してブラウザで表示確認。

問題なく確認できたので、次は写真を用意して `public/images/image.jpg` に置いてアクセスしてみる。が、もちろん表示されない。コンテントフェーズをフックしているからこれは当たり前なので、フックする箇所をアクセスフェーズに変更するように `nginx.conf` を書き換える。

```nginx
location / {
    access_by_lua_file  luahooks/image.lua;
}
```

そして `image.lua` もエラーログにアクセスしてきた URL を出力するように書き換える。

```lua
ngx.log( ngx.ERR, ngx.var.uri );
```

これで表示されるようになった。次はこの写真を変換する処理を作ってみる。

## OpenRestyでイメージフィルタ｜実装

そんなわけでリクエストをどう処理するかなんだけれど、クエリパラメータが多いと面倒なので Gravater - http://en.gravatar.com  っぽく `s=<size>` として正方形イメージに変換する。あともう一つ `q=<quality>` で画質も調整できるようにしておこう。ということで URL は `http://localhost:1080/image.jpg?s=100&q=50` という風になる。クエリパラメータが無い時はそのままの画像を返す。

処理の流れは以下のような感じ。

1. クエリパラメータをチェックする。
2. リクエストされた画像が存在するかの確認。
3. クエリパラメータに従って画像を変換する。
4. 変換した画像を返す。

どうやるか決まったので、これらの処理に必要なライブラリをインストールする。変換処理には `Imlib2` ライブラリを利用するので `brew install imlib2` でインストールした後に `luarocks install lua-imlib2` でモジュールをインストールする。それからリクエストされた画像の存在確認もする必要があるので、画像パスの存在確認用に `luaposix` モジュールも `luarocks install luaposix` としてインストールしておく。


### クエリーパラメータの処理と画像ファイルの存在確認

インストールが終わったら空っぽだった `init.lua` に以下のように書いてライブラリを読み込む。別に `image.lua` に書いてもいいんだけど、後々ファイルが増えたりした場合とか管理のわかりやすさの面から個人的に分けちゃうくせが付いてるだけなんだけどね。

```lua
require('posix');
require('imlib2');
```

クエリパラメータと画像の存在確認部分までの処理を `image.lua` に書いてみる。

```lua
local args = ngx.req.get_uri_args();
local size = tonumber( args.s );
local quality = tonumber( args.q );

if size or quality then
    local img = posix.realpath( ngx.var.document_root .. '/' .. ngx.var.uri );
    
    if img then
        ngx.log( ngx.ERR, img, ' size:', size, ' quality:', quality );
    end
end
```

これでブラウザから画像ファイルにアクセスすると、エラーログに画像ファイルの実パスとサイズと画質の指定値のログが吐き出されるのが確認できた。

### 画像ファイルの変換と保存

ここまできたら後は変換してブラウザに返すだけなんだけど `lua-imlib2` には画質を設定する項目がなかった。。。なんか面倒になって放置しようかと思ったけど、ふて寝して晩ご飯食べたらせっかくだしとやる気が復活。というわけで `luarocks remove lua-imlib2` で削除して、代わりにシンプルな `lua-thumbnailer` - https://github.com/mah0x211/lua-thumbnailer というモジュールを書いたので、これを `luarocks install https://raw.githubusercontent.com/mah0x211/lua-thumbnailer/master/thumbnailer-scm-1.rockspec` てな感じでインストールして `init.lua` も以下のように変更しとく。

```lua
thumbnailer = require('thumbnailer');
```

それから `image.lua` の処理を以下のようにクエリパラメータの調整やエラー処理も追加したりして、ごそっと書き換えます。

```lua
local args = ngx.req.get_uri_args();
local size = tonumber( args.s );
local quality = tonumber( args.q );

-- size value should be larger than 0
size = size and size > 0 and size or nil;
-- quality value should be 1 to 100
quality = quality and quality > 0 and quality <= 100 and quality or nil;

if size or quality then
    local img = posix.realpath( ngx.var.document_root .. '/' .. ngx.var.uri );
    
    if img then
        local filename, name, ext = ngx.var.uri:match( '(([^/.]+)%.(%w+))$' );
        local uri = ngx.var.uri:gsub( filename .. '$', 
                                      table.concat({name, size, quality}, '-' ) 
                                      .. '.' .. ext );
        
        -- set thumbnail-uri if it exists
        if posix.realpath( ngx.var.document_root .. '/' .. uri ) then
            ngx.req.set_uri( uri );
        else
            local err;
            img, err = thumbnailer.load( img );
            
            if img then
                
                if size then
                    -- resize( width, height, crop, horizontal_align, vertical_align )
                    img:resize( size, size, true, thumbnailer.ALIGN_CENTER, 
                                thumbnailer.ALIGN_MIDDLE );
                end
                
                if quality then
                    img:quality( quality );
                end
                
                err = img:save( ngx.var.document_root .. uri );
                if not err then
                    ngx.req.set_uri( uri );
                end
            end
            
            -- got error
            if err then
                ngx.log( ngx.ERR, err );
            end
        end
    end
end
```

これで画像のURL `http://localhost:1080/image.jpg?s=100&q=50` にアクセスするとサイズが100x100で画質が50のサムネイルが生成される。


## OpenRestyでイメージフィルタ｜まとめ

そんなこんなで、結局 C でモジュール書くはめになっちゃって休日を一日使ってしまってお気軽とはいかなかったけど、普通に nginx モジュールを書いたりするよりはお手軽ではないかと・・（苦）それと、今回作ったファイル一式は github に上げてるので触ってみたい人は気軽にどうぞ。

experimental-resty-imagefilter - https://github.com/mah0x211/experimental-resty-imagefilter

ちなみに、画像を保存してる箇所がボトルネックになってるので、次回はこの辺をどうにか出来ないか実験してみたいと思う。


## OpenRestyでイメージフィルタ｜追記

`lua-thumbnailer` はあまり考え無しで書いたので保存出来るのはクロップ・リサイズのみだったけど、今回はちょっとコードを見直して冗長な定数名の変更やデフォルトアライメントを水平垂直センターに変更、それからストレッチ・リサイズとクロップ・リサイズ、アスペクト・リサイズ、トリム・リサイズの4種類の保存方法を追加した。

- ストレッチ：リサイズ領域に合わせて引き延ばす。
- クロップ：アスペクト比を固定したままリサイズ領域に高さ・幅どちらかが合うようにリサイズし、リサイズ領域からはみだした画像は切り取られる。
- アスペクト：アスペクト比を固定したままリサイズ領域に収まるようにリサイズし、高さ・幅どちらかの余った部分はHSLaで指定した色（デフォルトは黒色）で塗りつぶされる。
- トリム：アスペクト比を固定したままリサイズ領域に収まるようにリサイズし、高さ・幅どちらかの余った部分は切り取られる。

この変更に伴ってAPIも変わったのでまずはその部分を修正しようと思うけど、その他にも構成を見直したり、コードの見通しがあまりよろしくないので処理の分割、エラー処理コードの追加、共有メモリやロック機構を利用するコードも追加していきたいと思う。


## OpenRestyでイメージフィルタ｜構成の見直し

ということで、まずは構成を見直して以下のようなディレクトリ構成にする。

```
./img-server/
├── conf
│   ├── mime.types
│   └── nginx.conf
├── logs
│   ├── access.log
│   └── error.log
├── luahooks
│   ├── image.lua
│   └── init.lua
└── public
    └── images
        ├── _cached/
        └── image.jpg
```

違いは `_cached` ディレクトリがあるかないかって点だけで、ここにサムネイル画像を生成する。それから、このキャッシュディレクトリに直接アクセスされるのもよろしくないのでアクセス制限をかけたり、ファイルシステムへのアクセスを必要最低限にするために共有メモリを利用したり、同時アクセス時に同じサムネイル画像を生成するのを防ぐためにロック機構を利用するので `nginx.conf` の設定も修正する。

```nginx
worker_processes    2;
events {
    worker_connections  1024;
    accept_mutex_delay  100ms;
}

http {
    sendfile            on;
    tcp_nopush          on;
    open_file_cache     off; # max=100;
    include             mime.types;
    default_type        text/html;
    index               index.html;
    
    #
    # log settings
    #
    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for"';
    access_log  logs/access.log main;
    
    # 
    # lua global settings
    #
    lua_package_path        '$prefix/luahooks/?.lua;;';
    lua_check_client_abort  on;
    lua_code_cache          on;
    lua_shared_dict         thumbnails 10m;
    lua_shared_dict         resty_lock 1m;
    
    #
    # initialize script
    #
    init_by_lua_file        luahooks/init.lua;
    
    #
    # public
    #
    server {
        listen      1080;
        root        public/images;
        
        #
        # variables
        #
        set $cache_dir '/_cached/';
        
        #
        # restrict cache directory
        #
        location ~ ^/_cached/ {
            internal;
        }
        
        #
        # access handler for .jpg
        #
        location ~* \.(jpg)$ {
            access_by_lua_file  luahooks/image.lua;
        }
    }
}
```

この `lua_shared_dict thumbnails 10m;` と `lua_shared_dict resty_lock 1m;` という箇所が共有メモリの設定箇所。サムネイルの存在確認用に `10MB` とロック用に `1MB` を割り当てる。もちろん値はテキトーに決めている。

きちんとやりたい時は、サムネイル画像URIからハッシュ値を生成してハッシュ文字列の長さx取り扱うファイル数分のメモリを割り当てるとよいかも。

それから `set $cache_dir '/_cached/';` で nginx の変数を宣言してる。これは `image.lua` にハードコードしたくない時にはこうする感じ。

次に `location ~ ^/_cached/` でキャッシュディレクトリへのアクセス制限を `internal` でかけておく。この方が楽だし的な。

あと、画像ファイル以外のリクエストの場合にも変換処理が走るにはまずいので `location ~* \.(jpg)$` で拡張子が `jpg` のみのリクエストに制限。

ちなみに `open_file_cache off; # max=100;` という箇所は、試行錯誤してる時に nginx にキャッシュされてるやりずらいという理由でオフにしてるだけ。


## OpenRestyでイメージフィルタ｜ソースコードの修正

早速ソースコードを修正していくけど、`lua-thumbnailer` に API を追加したので画像のリサイズオプションとして `a=<stretch|aspect|trim>` というクエリーパラメータを一つ追加する。指定しない場合はクロップ・リサイズになる。

### `resty.lock` を利用する

サムネイルの同時生成防止にロック機構を利用するのだけれど、それでプロセスが止まると困る。どうしたものかなとドキュメント見てたら `resty.lock` というモジュールが用意されてたのでこれを利用する。`init.lua` を以下のように修正する。

```lua
require('posix');
thumbnailer = require('thumbnailer');
restyLock = require('resty.lock');
```

`resty.lock` の実装を覗いてみると `while` ループの中にノンブロックなスリープ API `ngx.sleep` を挟んでる感じ。色々オプションもあるけどとりあえずデフォルト設定のままで利用する。もっと知りたい人は http://github.com/agentzh/lua-resty-lock に詳しく書いてありますよ。

次は `image.lua` を大幅に修正してく。

### リサイズオプション・クエリーパラメータチェック用のテーブル

これは個人的なスタイルなのであってもなくても良いのだけれど、新しく追加したリサイズオプションのチェック時に `if-elseif-else` を書き下してくのが面倒なので事前にテーブルで定義しておく。

```lua
local IMG_SAVE_AS = {
    stretch = 'stretch',
    aspect = 'aspect',
    trim = 'trim'
};
```

### ロックとアンロック


```lua
local function acquireLock( key )
    local lock = restyLock:new( 'resty_lock' );
    local elapsed, err = lock:lock( key );
    
    if err then
        lock = nil;
        ngx.log( ngx.ERR, 'failed to acquire the lock: ', err );
    end
    
    return lock, elapsed, err;
end
```

`acquireLock` 関数は以下の引数で呼び出すことでロック変数（？）を返し、失敗した場合はエラーを返す。

- `key`: ロックキー

ちなみに `'resty_lock'` というのが `nginx.conf` に書いたロック用の共有メモリの名前。

```lua
local function releaseLock( lock )
    local ok, err = lock:unlock();
    
    if err then
        ngx.log( ngx.ERR, 'failed to release the lock: ', err );
    end
    
    return ok, err;
end
```

`releaseLock` 関数は以下の引数で呼び出すことでロックを解除し `true` を返し、失敗した場合はエラーを返す。ロックをしたら必ず解除しないといけないけど、デフォルトで30秒でタイムアウトするようになってるっぽいのでロックされっぱなしということはなさそう。


### サムネイル画像の作成

```lua
local function createThumbnail( src, uri, qry )
    local img, err = thumbnailer.load( src );
    
    if img then
        img:size( qry.size, qry.size );
        
        if qry.quality then
            img:quality( qry.quality );
        end
        
        if qry.asa == 'stretch' then
            err = img:save( ngx.var.document_root .. uri );
        elseif qry.asa == 'aspect' then
            err = img:saveAspect( ngx.var.document_root .. uri );
        elseif qry.asa == 'trim' then
            err = img:saveTrim( ngx.var.document_root .. uri );
        else
            err = img:saveCrop( ngx.var.document_root .. uri );
        end
        -- remove internal buffer
        img:free();
    end
    
    -- got error
    if err then
        ngx.log( ngx.ERR, 'failed to create thumbnail: ', err );
        return false;
    end
    
    return true;
end
```

`createThumbnail` 関数は以下の引数で呼び出すことでドキュメントルート配下の `uri` パスへサムネイル画像を生成し `true` を返し、失敗した場合は `false` を返す。

- `src`: ソースパス
- `uri`: サムネイル画像のURI
- `qry`: クエリーテーブル
  - `size`: 縦横のサイズ値
  - `quality`: 画質は `1` から `100` までの値を指定。デフォルトは `100` になる。
  - `asa`: リサイズ方法 `stretch`、`'aspect'` または `'trim'` を指定できる。デフォルトは `'crop'` になる。


ちなみに、`ngx.var` というのは nginx の変数にアクセスするためのテーブル。画像の保存は nginx がアクセス可能なファイルシステム上のパスを指定する必要があるので `ngx.var.document_root .. uri` でドキュメントルートと `uri` を結合している。でも `uri` に `../../` こんな文字列が含まれてると危険なので呼び出す際には注意。


### ソースファイルの存在確認

```lua
local function getSourcePath()
    local src, err = posix.realpath( ngx.var.document_root .. '/' .. 
                                     ngx.var.uri );
    
    if err then
        ngx.log( ngx.WARN, 'failed to get realpath: ', err );
    end
    
    return src;
end
```

`getSourcePath` 関数は `posix.realpath` を利用してリクエストされた画像の存在確認をする。存在するならファイルシステム上のパスを返し、存在しない場合やその他のエラーがあれば `nil`を返す。


### サムネイル画像の存在確認

```lua
local function hasThumbnail( uri )
    local lock, elapsed, err = acquireLock( 'thumblock' );
    
    if lock then
        local ok;
        
        -- check the cache
        ok, err = ngx.shared.thumbnails:get( uri );
        if err then
            ngx.log( ngx.ERR, 'failed to check the cache: ', err );
            releaseLock( lock );
        -- already exists
        elseif ok then
            ok, err = releaseLock( lock );
            if ok then
                return true;
            end
            
            lock = nil;
        end
    end
    
    return false, lock;
end
```

`hasThumbnail` 関数は以下の引数で呼び出すことでサムネイル画像が存在するかチェックする。前のコードでは存在チェックのために毎回 `posix.realpath` を使っていたのでそれを共有メモリを利用するように変更。存在する場合は `true` を返し、存在しない場合は `false` とロック変数 `lock` を返す。ロックに失敗した場合は `false` と `nil` を返す。

- `uri`: サムネイル画像のURI


### サムネイル画像URIの構築

```lua
local function genThumbnailURI( qry )
    local filename, name, ext = ngx.var.uri:match( '(([^/]+)(%.%w+))$' );
    local tbl = { name };
    
    table.foreachi( { 'size', 'quality', 'asa' }, function( i, v )
        if qry[v] then
            tbl[#tbl+1] = qry[v];
        end
    end);
    
    -- to change /path/name.ext to /path/cached/name-size-quality-asa.ext
    return ngx.var.uri:gsub( 
        filename .. '$', ngx.var.cache_dir .. table.concat( tbl, '-' ) .. ext 
    );
end
```

`genThumbnailURI` 関数は以下の引数で呼び出すことでリクエストURIを元にしてサムネイル画像URIを生成して返す。今回はテキトーに `/path/to/image.jpg?s=100&q=100&a=trim` というリクエストなら生成されるサムネイル画像URIは `/_cached/path/to/image-100-100-trim.jpg` という風に変換している。

- `qry`: クエリーテーブル


### リクエスト URI をサムネイル画像 URI に変更

```lua
local function switchToThumbnail( qry )
    local uri = genThumbnailURI( qry );
    local ok, lock, err = hasThumbnail( uri );
    
    -- set thumbnail-uri if it exists
    if ok then
        ngx.req.set_uri( uri );
    elseif lock then
        local src = getSourcePath();
            
        -- source file exists
        if src then
            -- set thumbnail-uri if created
            if createThumbnail( src, uri, qry ) then
                ngx.shared.thumbnails:set( uri, true );
                ngx.req.set_uri( uri );
            end
        end
        
        releaseLock( lock );
    end
end
```

`switchToThumbnail` 関数は以下の引数で呼び出すことでサムネイル画像の存在確認をし、存在するならリクエスト URI にサムネイル画像URIに設定する。

存在しなければ、ソースファイルの存在確認をしてサムネイル画像を生成、存在確認用の共有メモリへサムネイル画像 URI をキーにしてテキトーな値を保存。その後、リクエスト URI にサムネイル画像 URI に設定してロックを解除する。

こんな風にリクエスト URI を変更することで nginx にファイルの読込みや送信、キャッシュ周りの処理を全て委譲することができる。

- `qry`: クエリーテーブル


### クエリーパラメータのチェック

```lua
local function getQuery()
    local args = ngx.req.get_uri_args();
    local size = tonumber( args.s );
    local quality = tonumber( args.q );
    
    -- size value should be larger than 0
    size = size and size > 0 and size < math.huge and size or nil;
    -- quality value should be 1 to 100
    quality = quality and quality > 0 and quality <= 100 and quality or nil;
    
    return {
        size = size, 
        quality = quality,
        asa = IMG_SAVE_AS[args.a]
    };
end
```

`getQuery` 関数を呼び出すことでクエリーパラメータの値をチェックしてテーブルを返す。まぁ、コードのみたまま感じ。

ちなみに、`size < math.huge` としてるのでサイズ値に `30000` とか入れられちゃうとあっとゆーまにメモリが枯渇、スワッピングが起こりファンが高速回転しだすのでとっても危険です。なのでお試しに動かす時でも制限かけておいた方がよいです。

### リクエストのチェック

```lua
local function checkRequest()
    local qry = getQuery();
    
    if qry.size then
        switchToThumbnail( qry );
    end
end

checkRequest();
```

`checkRequest` 関数を呼び出すことでクエリーパラメータの `size` 値があるなら `switchToThumbnail` を呼び出す。

`checkRequest` 関数を作る必要は特にないんだけど、個人的にうっかり別の関数から変数にアクセスしちゃうコード書いちゃいそうなんで変数をごにょごにょして渡すって処理を書く時は javascript 書く時も perl 書く時もこんな風に書いちゃうクセが付いてるだけです。


## OpenRestyでイメージフィルタ｜追記のまとめ

ということで、説明なげーよ！ってな感じで無駄に長文すぎて、まったくもってお気軽感がなくなってしまった感がある。

OpenResty にはここで使ったもの以外にも色々な機能が用意されてるので、気になった人は https://github.com/openresty/lua-nginx-module/ を読むのが一番のオススメです。

またなんか思いついたら書きます。

