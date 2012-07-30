/*
 CDBFile.m
 Created by Jens Alfke on 2/3/08.

 Copyright (c) 2008, Jens Alfke. All rights reserved.
 
 Redistribution and use in source and binary forms, with or without modification, are permitted
 provided that the following conditions are met:
 
 * Redistributions of source code must retain the above copyright notice, this list of conditions
 and the following disclaimer.
 * Redistributions in binary form must reproduce the above copyright notice, this list of conditions
 and the following disclaimer in the documentation and/or other materials provided with the
 distribution.
 
 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR
 IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND 
 FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRI-
 BUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR 
  PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN 
 CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF 
 THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */


#import "CDBFile.h"


CDBData CDBFromNSData( NSData* d )
{
    return (CDBData){d.bytes,d.length};
}

CDBData CDBFromCString( const char *cstr )
{
    return (CDBData){cstr, cstr ?strlen(cstr) :0};
}

CDBData CDBFromNSString( NSString* str )
{
    if( ! str )
        return (CDBData){NULL,0};
    const char *cstr = CFStringGetCStringPtr((CFStringRef)str, kCFStringEncodingUTF8);
    if( cstr )
        return CDBFromCString(cstr);
    else
        return CDBFromNSData([str dataUsingEncoding: NSUTF8StringEncoding]);
}

NSData* CDBToNSData( CDBData d )
{
    if( d.bytes )
        return [NSData dataWithBytes: d.bytes length: d.length];
    else
        return nil;
}

NSData* CDBToNSDataNoCopy( CDBData d )
{
    if( d.bytes )
        return [NSData dataWithBytesNoCopy: (void*)d.bytes length: d.length freeWhenDone: NO];
    else
        return nil;
}

NSString* CDBToNSString( CDBData d )
{
    if( d.bytes )
        return [[[NSString alloc] initWithBytes: d.bytes length: d.length encoding: NSUTF8StringEncoding]
                    autorelease];
    else
        return nil;
}



@interface CDBEnumerator ()
- (id) initWithCDBReader: (CDBReader*)db;
@end




@implementation CDBFile


- (id) initWithFile: (NSString*)path
{
    self = [super init];
    if (self != nil) {
        _path = [path copy];
    }
    return self;
}

- (void) dealloc
{
    if( _fd > 0 ) [self close];
    [_path release];
    [super dealloc];
}

- (void) finalize
{
    if( _fd > 0 ) [self close];
    [super finalize];
}    


- (BOOL) _open: (int)mode
{
    if( _fd > 0 )
        return YES;
    _fd = open([_path fileSystemRepresentation], mode, 0644);
    if( _fd <= 0 ) {
        _error = errno;
        return NO;
    } else {
        _error = 0;
        return YES;
    }
}

- (BOOL) open
{
    return NO; // abstract
}

- (BOOL) close
{
    if( _fd > 0 ) {
        close(_fd);
        _fd = 0;
    }
    return YES;
}

- (BOOL) deleteFile
{
    [self close];
    if( unlink([_path fileSystemRepresentation]) == 0 )
        return YES;
    else {
        _error = errno;
        return NO;
    }
}


@synthesize file=_path, fileDescriptor=_fd;

- (BOOL) isOpen
{
    return _fd > 0;
}

- (NSError*) error
{
    if( _error )
        return [NSError errorWithDomain: NSPOSIXErrorDomain code: _error userInfo: nil];
    else
        return nil;
}

- (void) _setErrno: (int)err
{
    _error = err;
}

- (void) clearError
{
    _error = 0;
}


@end




@implementation CDBReader


- (id) initWithFile: (NSString*)path
{
    return [super initWithFile: path];
}

- (BOOL) open
{
    if( cdb_fileno(&_cdb) > 0 )
        return YES;
    if( ! [super _open: O_RDONLY] )
        return NO;
    
    if( cdb_init(&_cdb,self.fileDescriptor) < 0 ) {
        [self _setErrno: errno];
        [super close];
        return NO;
    }
    return YES;
}

- (BOOL) close
{
    if( cdb_fileno(&_cdb) > 0 ) {
        cdb_free(&_cdb);
        cdb_fileno(&_cdb) = 0;      // for some reason cdb_free doesn't clear this
    }
    return [super close];
}

- (CDBData) valuePointerForKey: (CDBData)key
{
    NSParameterAssert(key.bytes!=NULL);
    NSAssert(cdb_fileno(&_cdb)>0, @"File is not open");
    CDBData result;
    int found = cdb_find(&_cdb,key.bytes,(unsigned)key.length);
    if( found > 0 ) {
        result.bytes = cdb_getdata(&_cdb);
        result.length = cdb_datalen(&_cdb);
    } else {
        result.bytes = NULL;
        result.length = 0;
        if( found < 0 )
            [self _setErrno: errno];
    }
    return result;
}


- (CDBEnumerator*) keyEnumerator
{
    return [[[CDBEnumerator alloc] initWithCDBReader: self] autorelease];
}

- (struct cdb*)_cdb
{
    return &_cdb;
}


@end




@implementation CDBWriter


- (id) initWithFile: (NSString*)path
{
    return [super initWithFile: path];
}

- (BOOL) open
{
    if( _cdbmake.cdb_fd>0 )
        return YES;
    if( ! [super _open: O_RDWR | O_CREAT | O_TRUNC] )
        return NO;
    if( cdb_make_start(&_cdbmake,self.fileDescriptor) < 0 ) {
        [self _setErrno: errno];
        [super close];
        return NO;
    }
    return YES;
}

- (BOOL) close
{
    BOOL ok;
    if( self.isOpen ) {
        ok = cdb_make_finish(&_cdbmake) == 0;
        if( ! ok )
            [self _setErrno: errno];
        _cdbmake.cdb_fd = 0;            // for some reason cdb_make_finish doesn't clear this
        [super close];
    } else
        ok = YES;
    return ok;
}


- (BOOL) addValuePointer: (CDBData)value forKey: (CDBData)key
{
    return [self addValuePointers: &value count: 1 forKey: key];
}

- (BOOL) addValuePointers: (const CDBData[])values count: (unsigned)count forKey: (CDBData)key
{
    NSParameterAssert(key.bytes!=NULL);
    NSAssert(_cdbmake.cdb_fd>0, @"CDBWriter is not open");
    if( count==0 || values[0].bytes==NULL || cdb_make_addv(&_cdbmake, key.bytes, (unsigned)key.length, 
                                                           (const struct cdb_iovec*)values, count) == 0 )
        return YES;
    else {
        [self _setErrno: errno];
        return NO;
    }
}


@end




@implementation CDBEnumerator


- (id) initWithCDBReader: (CDBReader*)db
{
    self = [super init];
    if (self != nil) {
        _cdb = db._cdb;
        NSAssert(cdb_fileno(_cdb)>0, @"File is not open");
        cdb_seqinit(&_seq,_cdb);
        _db = [db retain];
    }
    return self;
}

- (void) dealloc
{
    [_db release];
    [super dealloc];
}

- (BOOL) next
{
    if( ! _db )
        return NO;
    NSAssert(cdb_fileno(_cdb)>0, @"CDBReader was closed");
    if( cdb_seqnext(&_seq,_cdb) <= 0 ) {
        // EOF:
        [_db release];
        _db = nil;
        _cdb = NULL;
        _value.bytes = _key.bytes = NULL;
        _value.length = _key.length = 0;
        return NO;
    }
    _value.bytes = cdb_getdata(_cdb);
    _value.length = cdb_datalen(_cdb);
    _key.bytes = cdb_getkey(_cdb);
    _key.length = cdb_keylen(_cdb);
    return YES;
}

- (id) nextObject
{
    [self next];
    return CDBToNSData(_key);
}

- (CDBData) valuePointer
{
    return _value;
}

- (CDBData) keyPointer
{
    return _key;
}


@end
