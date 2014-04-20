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


