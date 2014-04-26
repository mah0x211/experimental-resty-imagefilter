local IMG_SAVE_AS = {
    stretch = 'stretch',
    aspect = 'aspect',
    trim = 'trim'
};

local function acquireLock( key )
    local lock = restyLock:new( 'resty_lock' );
    local elapsed, err = lock:lock( key );
    
    if err then
        lock = nil;
        ngx.log( ngx.ERR, 'failed to acquire the lock: ', err );
    end
    
    return lock, elapsed, err;
end


local function releaseLock( lock )
    local ok, err = lock:unlock();
    
    if err then
        ngx.log( ngx.ERR, 'failed to release the lock: ', err );
    end
    
    return ok, err;
end


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


local function getSourcePath()
    local src, err = posix.realpath( ngx.var.document_root .. '/' .. 
                                     ngx.var.uri );
    
    if err then
        ngx.log( ngx.WARN, 'failed to get realpath: ', err );
    end
    
    return src;
end


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


local function checkRequest()
    local qry = getQuery();
    
    if qry.size then
        switchToThumbnail( qry );
    end
end


checkRequest();

