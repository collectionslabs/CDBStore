/*
 CDBStore.h
 Created by Jens Alfke on 2/4/08.

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


/** An implementation of a persistent mutable dictionary, using a CDB file as the backing store.
    
    Compared to a property list, a CDBStore is more flexible: the values can be any objects
    that support the NSCoding protocol, and the dictionary can be changed in place and saved
    back to the file. CDBStore also scales better, since the keys and values aren't
    read into memory until accessed.
 
    Compared to CoreData, CDBStore is much simpler to use, especially if you want to retrofit
    existing code that uses NSDictionaries or property lists. It's also faster at what it does,
    since it doesn't have the overhead of a SQL interpreter and object-relational mapping.
    However, it is of course much more limited in functionality, as the only sorts of "queries"
    it offers are simple key-identity lookups.
 
    How it works:
 
    Keys are translated into raw data blobs and looked up in a CDBReader. The data values are
    translated into NSObjects, using an NSKeyedUnarchiver if necessary, and stored in an
    in-memory cache dictionary for speedy subsequent lookups (with object-identity.)
 
    A modified value is stored back into the cache, and the key is marked as being changed.
 
    To save the store, a CDBWriter is created on a temporary file, and all of the key/value
    pairs are written to it. Unmodified, undeleted values are copied directly over as data from
    the old CDB file, while modified or inserted values are first archived into NSData and
    then written. After this completes successfully, the original file is atomically replaced
    with the new file. This guarantees that the file always exists and is valid; if anything
    goes wrong while saving, or the system crashes, the worst that happens is that the latest
    changes are lost. */

@interface CDBStore : NSObject
{
    @private
    NSString *_path;
    CDBReader *_reader;
    NSMutableDictionary *_cache;
    NSMutableSet *_changedEncodedKeys;
    NSTimeInterval _autosaveInterval;
    BOOL _isOpen, _savingSoon;
}

/** Creates a CDBStore that will read from the given file, which must be in CDB format.
    The file will not be opened or read from until the -open method is called. */
- (id) initWithFile: (NSString*)path;

/** The path of the CDBStore's file. */
@property (readonly) NSString *file;

/** Opens the CDB file for reading.
    If an error occurs, returns NO and sets *outError.
    It is not an error for the file to be missing: CDBStore treats this as an empty file,
    and will create the file the first time -save: is called.
    If the file is already open, this method does nothing and returns YES. */
- (BOOL) open: (NSError**)outError;

/** Closes the CDBStore. Any unsaved changes are saved to the file, and the file is closed.
    The object cache is emptied.
    Afterwards, the store's objects cannot be accessed unless the store is re-opened.
    The store is implicitly closed when dealloced or finalized, but it's better to close it
    manually when you're done with it, in case a dangling reference bug prevents the object
    from being cleaned up. */    
- (BOOL) close;

/** Is the CDBStore open? */
@property (readonly) BOOL isOpen;

/** Does the backing file exist yet? */
@property (readonly) BOOL exists;

/** Empties the in-memory cache of already-read values.
    Unsaved changes are kept in the cache, however. */
- (void) emptyCache;

/** Just as in an NSDictionary, returns the object associated with the key, or else nil.
    @param key  The dictionary key. By default, only NSData objects are allowed.
                Additional types of keys can be supported by subclassing CDBStore and overriding the
                -encodeKey: and decodeKey: methods.
    @return     The value associated with the key, or nil if there is none. */
- (id) objectForKey: (id)key;

/** Returns an enumerator that will return all the keys in the store, in
    arbitrary order. */
- (NSEnumerator *)keyEnumerator;

/** Returns an enumerator that will return all the objects (values) in the store, in
    arbitrary order. */
- (NSEnumerator *)objectEnumerator;

/** Reads all keys and values into memory and returns them in the form of a regular NSDictionary.
    Needless to say, this can be very expensive if the file is large! */
- (NSDictionary*) allKeysAndValues;

/** Just as in an NSDictionary, associates an object with a key.
    @param object   The new value to associate with the key. 
                    A nil value is legal, and deletes any previous value associated with the key.
    @param key  The dictionary key. By default, only NSData objects are allowed.
                Additional types of keys can be supported by subclassing CDBStore and overriding the
                -encodeKey: and decodeKey: methods. */
- (void) setObject: (id)object forKey: (id)key;

/** Notifies the store that the object associated with the key has changed its persistent
    representation, and should be saved. */
- (void) objectChangedForKey: (id)key;

/** Notifies the store that the value object has changed its persistent representation, 
    and should be saved.
    This is slower than -objectChangedForKey:, and should only be used in contexts where
    you don't know the key associated with the object. */
- (void) objectChanged: (id)object;

/** Does the store contain any unsaved changes? */
@property (readonly) BOOL hasChanges;

/** The set of keys whose values have been added, changed or deleted since the last save. */
@property (readonly) NSSet* changedKeys;

/** Saves the store to its file, if any changes have been made.
    If the file didn't originally exist, this will create it.
    The file is saved atomically, by creating a new copy and swapping it in.
    (This is safer, but slower, than a typical database's save-in-place.) */
- (BOOL) save: (NSError**)outError;

/** The time interval after which the store will automatically save changes.
    The default value is zero, which denotes "never", disabling auto-save. */
@property NSTimeInterval autosaveInterval;

/** As an alternative to enabling autosave, you can call this method to schedule a save "soon"
    (at the end of the current run-loop cycle.) Multiple consecutive calls to this method 
    only result in one save. */
- (void) saveSoon;


/** @name For subclasses to override */
// @{

/** Encodes a key as raw bytes for use as a CDB key. 
    By default this only supports NSData objects.
    @param key  The key passed to a public API call like -objectForKey:.
    @return     A CDBData pointing to the raw bytes to use as the CDB key. This can point to
                autoreleased memory, but not to local variables of your method! */
- (CDBData) encodeKey: (id)key;

/** Decodes raw CDB key bytes back into a key object.
    By default this creates NSData objects.
    @param keyData  Points to the raw CDB key read from the file.
    @return         The object form of the key. */
- (id) decodeKey: (CDBData)keyData;

/** Encodes a value as raw bytes for use as a CDB value.
    By default this supports any NSCoding-compliant object, with optimizations for NSData and NSString.
    @param object   The object (value) to be encoded.
    @param outTag   On return, should be set to a byte value that distinguishes the type of
                    encoding used. The values 0..31 are reserved; subclasses should use other values.
    @return         The data to write to the CDB file representing the value. */
- (NSData*) encodeObject: (id)object tag: (UInt8*)outTag;

/** Decodes a raw CDB value into an object: the inverse of -encodeObject:.
    Overrides should inspect the tag; if it matches a custom tag that they encode, they
    should decode and return the object. Otherwise call the inherited method.
    @param data     Points to the raw data from the CDB file (which was originally created by
                    a call to -encodeObject:tag:.)
    @param tag      The tag associated with the data in the file (originally returned from
                    -encodeObject:tag:.)
    @return         The object that the data decodes into. */
- (id) decodeObject: (CDBData)data tag: (UInt8)tag;

// }@

@end


/** A subclass of CDBStore that takes NSStrings, instead of NSData, as keys. */
@interface CDBStringKeyStore : CDBStore
@end

