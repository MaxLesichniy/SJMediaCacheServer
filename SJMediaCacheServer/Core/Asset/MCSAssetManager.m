//
//  MCSAssetManager.m
//  SJMediaCacheServer_Example
//
//  Created by 畅三江 on 2020/6/3.
//  Copyright © 2020 changsanjiang@gmail.com. All rights reserved.
//

#import "MCSAssetManager.h"
#import <objc/message.h>

#import "MCSDatabase.h"
#import "MCSUtils.h"
#import "MCSAssetUsageLog.h"
#import "NSFileManager+MCS.h"
 
#import "FILEReader.h"
#import "FILEAsset.h"
 
#import "HLSReader.h"
#import "HLSAsset.h"

#import "MCSRootDirectory.h"
#import "MCSConsts.h"
 
static dispatch_queue_t mcs_queue;

#pragma mark - Private

@interface MCSAssetUsageLog (MCSPrivate)
@property (nonatomic) NSInteger id;
@property (nonatomic) NSUInteger usageCount;

@property (nonatomic) NSTimeInterval updatedTime;
@property (nonatomic) NSTimeInterval createdTime;

@property (nonatomic) NSInteger asset;
@property (nonatomic) MCSAssetType assetType;
@end
  
@interface HLSAsset (HLSPrivate)
@property (nonatomic, weak, nullable) HLSAsset *root;
@end

//@interface FILEAsset (FILEPrivate)
//@end

#pragma mark -

@interface MCSAssetManager () {
    NSUInteger _countOfAllAssets;
}
@property (nonatomic, strong) NSMutableDictionary<NSString *, id<MCSAsset> > *assets;
@property (nonatomic, strong) NSMutableDictionary<NSString *, MCSAssetUsageLog *> *usageLogs;
@property (nonatomic, strong) SJSQLite3 *sqlite3;
@end

@implementation MCSAssetManager
+ (instancetype)shared {
    static id obj = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        mcs_queue = mcs_dispatch_queue_create("queue.MCSAssetManager", DISPATCH_QUEUE_CONCURRENT);
        obj = [[self alloc] init];
    });
    return obj;
}

- (instancetype)init {
    self = [super init];
    if ( self ) {
        _sqlite3 = MCSDatabase();
        _countOfAllAssets = [_sqlite3 countOfObjectsForClass:MCSAssetUsageLog.class conditions:nil error:NULL];
        _assets = NSMutableDictionary.dictionary;
        _usageLogs = NSMutableDictionary.dictionary;
        
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(_assetMetadataDidLoadWithNote:) name:MCSAssetMetadataDidLoadNotification object:nil];
    }
    return self;
}
 
#pragma mark -

- (nullable __kindof id<MCSAsset> )assetWithURL:(NSURL *)URL {
    MCSAssetType type = [MCSURL.shared assetTypeForURL:URL];
    NSString *name = [MCSURL.shared assetNameForURL:URL];
    return [self _assetWithName:name type:type];
}

- (nullable __kindof id<MCSAsset>)assetWithName:(NSString *)name type:(MCSAssetType)type {
    return [self _assetWithName:name type:type];
}

- (BOOL)isAssetStoredForURL:(NSURL *)URL {
    __block id<MCSAsset> asset = nil;
    dispatch_barrier_sync(mcs_queue, ^{
        NSString *name = [MCSURL.shared assetNameForURL:URL];
        asset = _assets[name];
        if ( asset != nil ) return;
        MCSAssetType type = [MCSURL.shared assetTypeForURL:URL];
        Class cls = [self _assetClassForType:type];
        if ( cls == nil ) return;
        asset = (id)[_sqlite3 objectsForClass:cls conditions:@[
            [SJSQLite3Condition conditionWithColumn:@"name" value:name]
        ] orderBy:nil error:NULL].firstObject;
        [asset prepare];
        if ( asset != nil ) _assets[name] = asset;
    });
    return asset.isStored;
}
 
- (nullable id<MCSAssetReader>)readerWithRequest:(NSURLRequest *)proxyRequest networkTaskPriority:(float)networkTaskPriority delegate:(nullable id<MCSAssetReaderDelegate>)delegate {
    NSURL *proxyURL = proxyRequest.URL;
    NSURL *URL = [MCSURL.shared URLWithProxyURL:proxyURL];
    MCSAssetType type = [MCSURL.shared assetTypeForURL:proxyURL];
    NSMutableURLRequest *request = [proxyRequest mcs_requestWithRedirectURL:URL];
    switch ( type ) {
        case MCSAssetTypeFILE: {
            FILEAsset *asset = [self assetWithURL:proxyURL];
            return [FILEReader.alloc initWithAsset:asset request:request networkTaskPriority:networkTaskPriority readDataDecoder:_readDataDecoder delegate:delegate];
        }
        case MCSAssetTypeHLS: {
            // If proxyURL has a playlist suffix, the proxyRequest may be requesting a sub-asset
            BOOL isPlaylistRequest = [proxyURL.lastPathComponent hasSuffix:HLS_SUFFIX_INDEX];
            HLSAsset *asset = [self assetWithURL:isPlaylistRequest ? URL : proxyURL];
            if ( isPlaylistRequest ) {
                HLSAsset *root = [self assetWithURL:proxyURL];
                BOOL isRootAsset = root != asset;
                if ( isRootAsset ) asset.root = root;
            }
            MCSDataType dataType = [MCSURL.shared dataTypeForProxyURL:proxyURL];
            return [HLSReader.alloc initWithAsset:asset request:request dataType:dataType networkTaskPriority:networkTaskPriority readDataDecoder:_readDataDecoder delegate:delegate];
        }
    }
    return nil;
}

- (void)removeAssetForURL:(NSURL *)URL {
    if ( URL.absoluteString.length == 0 )
        return;
    dispatch_barrier_sync(mcs_queue, ^{
        MCSAssetType type = [MCSURL.shared assetTypeForURL:URL];
        NSString *name = [MCSURL.shared assetNameForURL:URL];
        Class cls = [self _assetClassForType:type];
        if ( cls == nil ) return;
        id<MCSAsset> asset = (id)[_sqlite3 objectsForClass:cls conditions:@[
            [SJSQLite3Condition conditionWithColumn:@"name" value:name]
        ] orderBy:nil error:NULL].firstObject;
        if ( asset != nil ) [self _removeAssetsInArray:@[asset]];
    });
}

- (void)removeAsset:(id<MCSAsset>)asset {
    if ( asset == nil )
        return;
    dispatch_barrier_sync(mcs_queue, ^{
        [self _removeAssetsInArray:@[asset]];
    });
}

- (void)removeAssetsInArray:(NSArray<id<MCSAsset>> *)array {
    if ( array.count == 0 )
        return;
    dispatch_barrier_sync(mcs_queue, ^{
        [self _removeAssetsInArray:array];
    });
}

- (UInt64)countOfBytesAllAssets {
    return MCSRootDirectory.size - MCSRootDirectory.databaseSize;
}

- (NSInteger)countOfAllAssets {
    __block NSInteger count = 0;
    dispatch_sync(mcs_queue, ^{
        count = _countOfAllAssets;
    });
    return count;
}
 
- (void)willReadAssetForURL:(NSURL *)URL {
    id<MCSAsset> asset = [self assetWithURL:URL];
    if ( asset != nil ) {
        dispatch_barrier_async(mcs_queue, ^{
            MCSAssetUsageLog *log = self->_usageLogs[asset.name];
            if ( log == nil ) {
                log = (id)[self->_sqlite3 objectsForClass:MCSAssetUsageLog.class conditions:@[
                    [SJSQLite3Condition conditionWithColumn:@"asset" value:@(asset.id)],
                    [SJSQLite3Condition conditionWithColumn:@"assetType" value:@(asset.type)]
                ] orderBy:nil error:NULL].firstObject;
                self->_usageLogs[asset.name] = log;
            }
            
            if ( log != nil ) {
                log.usageCount += 1;
                log.updatedTime = NSDate.date.timeIntervalSince1970;
                [self->_sqlite3 update:log forKeys:@[@"usageCount", @"updatedTime"] error:NULL];
            }
        });
    }
}

- (UInt64)countOfBytesNotIn:(nullable NSDictionary<MCSAssetTypeNumber *, NSArray<MCSAssetIDNumber *> *> *)assets {
    __block UInt64 size = 0;
    dispatch_sync(mcs_queue, ^{
        NSArray<id<MCSAsset> > *results = [self _assetsNotIn:assets];
        for ( id<MCSAsset> asset in results ) {
            size += [NSFileManager.defaultManager mcs_directorySizeAtPath:asset.path];
        }
    });
    return size;
}

/// 读取中的资源不会被删除
///
- (void)removeAssetsForLastReadingTime:(NSTimeInterval)timeLimit notIn:(nullable NSDictionary<MCSAssetTypeNumber *, NSArray<MCSAssetIDNumber *> *> *)assets {
    [self removeAssetsForLastReadingTime:timeLimit notIn:assets countLimit:NSNotFound];
}

/// 读取中的资源不会被删除
///
- (void)removeAssetsForLastReadingTime:(NSTimeInterval)timeLimit notIn:(nullable NSDictionary<MCSAssetTypeNumber *, NSArray<MCSAssetIDNumber *> *> *)assets countLimit:(NSInteger)countLimit {
    dispatch_barrier_sync(mcs_queue, ^{
        // 过滤被使用中的资源
        NSMutableSet<NSNumber *> *readwriteFileAssets = NSMutableSet.set;
        NSMutableSet<NSNumber *> *readwriteHLSAssets = NSMutableSet.set;
        [_assets enumerateKeysAndObjectsUsingBlock:^(NSString * _Nonnull key, id<MCSAsset>  _Nonnull asset, BOOL * _Nonnull stop) {
            if ( asset.readwriteCount > 0 ) {
                NSMutableSet<NSNumber *> *set = (asset.type == MCSAssetTypeFILE ? readwriteFileAssets : readwriteHLSAssets);
                [set addObject:@(asset.id)];
            }
        }];
        
        // not in
        [assets enumerateKeysAndObjectsUsingBlock:^(MCSAssetTypeNumber * _Nonnull key, NSArray<MCSAssetIDNumber *> * _Nonnull obj, BOOL * _Nonnull stop) {
            NSMutableSet<NSNumber *> *set = (key.integerValue == MCSAssetTypeFILE ? readwriteFileAssets : readwriteHLSAssets);
            [set addObjectsFromArray:obj];
        }];
        
        // 全部处于使用中
        NSInteger count = readwriteFileAssets.count + readwriteHLSAssets.count;
        if ( count == _countOfAllAssets )
            return;
        
        [readwriteFileAssets addObject:@(0)];
        [readwriteHLSAssets addObject:@(0)];
        
        NSString *s0 = [readwriteFileAssets.allObjects componentsJoinedByString:@","];
        NSString *s1 = [readwriteHLSAssets.allObjects componentsJoinedByString:@","];

        NSArray<SJSQLite3RowData *> *rows = nil;
        if ( countLimit != NSNotFound ) {
            rows = [_sqlite3 exec:[NSString stringWithFormat:
                                   @"SELECT * FROM MCSAssetUsageLog WHERE (asset NOT IN (%@) AND assetType = 0) \
                                                                       OR (asset NOT IN (%@) AND assetType = 1) \
                                                                      AND updatedTime <= %lf \
                                                                 ORDER BY updatedTime ASC, usageCount ASC \
                                                                    LIMIT 0, %ld;", s0, s1, timeLimit, (long)countLimit] error:NULL];
        }
        else {
            rows = [_sqlite3 exec:[NSString stringWithFormat:
                            @"SELECT * FROM MCSAssetUsageLog WHERE (asset NOT IN (%@) AND assetType = 0) \
                                                                OR (asset NOT IN (%@) AND assetType = 1) \
                                                               AND updatedTime <= %lf;", s0, s1, timeLimit] error:NULL];
        }
        NSArray<MCSAssetUsageLog *> *logs = [_sqlite3 objectsForClass:MCSAssetUsageLog.class rowDatas:rows error:NULL];
        if ( logs.count == 0 )
            return;
        // 删除
        NSMutableArray<id<MCSAsset> > *results = NSMutableArray.array;
        [logs enumerateObjectsUsingBlock:^(MCSAssetUsageLog * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            id<MCSAsset> asset = [_sqlite3 objectForClass:[self _assetClassForType:obj.assetType] primaryKeyValue:@(obj.asset) error:NULL];
            if ( asset != nil ) [results addObject:asset];
        }];

        [self _removeAssetsInArray:results];
    });
}

- (void)removeAssetsNotIn:(nullable NSDictionary<MCSAssetTypeNumber *, NSArray<MCSAssetIDNumber *> *> *)assets {
    dispatch_barrier_sync(mcs_queue, ^{
        NSArray<id<MCSAsset> > *results = [self _assetsNotIn:assets];
        // 删除
        [self _removeAssetsInArray:results];
    });
}

#pragma mark - mark

- (void)_syncToDatabase:(id<MCSSaveable>)saveable {
    if ( saveable != nil ) {
        [_sqlite3 save:saveable error:NULL];
    }
}
 
#pragma mark - mark

- (nullable __kindof id<MCSAsset> )_assetWithName:(NSString *)name type:(MCSAssetType)type {
    __block id<MCSAsset> asset = nil;
    dispatch_barrier_sync(mcs_queue, ^{
        if ( _assets[name] == nil ) {
            Class cls = [self _assetClassForType:type];
            if ( cls == nil ) return;
            
            // query
            id<MCSAsset> r = (id)[_sqlite3 objectsForClass:cls conditions:@[
                [SJSQLite3Condition conditionWithColumn:@"name" value:name]
            ] orderBy:nil error:NULL].firstObject;
            
            // create
            if ( r == nil ) {
                r = [cls.alloc initWithName:name];
                [self _syncToDatabase:r]; // save asset
                _countOfAllAssets += 1;
            }
             
            [r prepare];
            _assets[name] = r;
        }
        
        asset  = _assets[name];
        
        if ( _usageLogs[name] == nil ) {
            MCSAssetUsageLog *log = (id)[_sqlite3 objectsForClass:MCSAssetUsageLog.class conditions:@[
                [SJSQLite3Condition conditionWithColumn:@"asset" value:@(asset.id)],
                [SJSQLite3Condition conditionWithColumn:@"assetType" value:@(asset.type)]
            ] orderBy:nil error:NULL].firstObject;
            
            if ( log == nil ) {
                log = [MCSAssetUsageLog.alloc initWithAsset:asset];
                [self _syncToDatabase:log]; // save log
            }
            
            _usageLogs[name] = log;
        }
    });
    return asset;
}

- (void)_assetMetadataDidLoadWithNote:(NSNotification *)note {
    dispatch_barrier_async(mcs_queue, ^{
        [self _syncToDatabase:note.object];
    });
}
 
 
- (void)_removeAssetsInArray:(NSArray<id<MCSAsset> > *)assets {
    if ( assets.count == 0 )
        return;

    [assets enumerateObjectsUsingBlock:^(id<MCSAsset>  _Nonnull r, NSUInteger idx, BOOL * _Nonnull stop) {
        [NSNotificationCenter.defaultCenter postNotificationName:MCSAssetWillRemoveAssetNotification object:r];
        [NSFileManager.defaultManager removeItemAtPath:r.path error:NULL];
        [self.sqlite3 removeObjectForClass:r.class primaryKeyValue:@(r.id) error:NULL];
        [self.sqlite3 removeAllObjectsForClass:MCSAssetUsageLog.class conditions:@[
            [SJSQLite3Condition conditionWithColumn:@"asset" value:@(r.id)],
            [SJSQLite3Condition conditionWithColumn:@"assetType" value:@(r.type)],
        ] error:NULL];
        [self.assets removeObjectForKey:r.name];
        [self.usageLogs removeObjectForKey:r.name];
        [NSNotificationCenter.defaultCenter postNotificationName:MCSAssetDidRemoveAssetNotification object:r];
    }];
    
    _countOfAllAssets -= assets.count;
}

- (Class)_assetClassForType:(MCSAssetType)type {
    return type == MCSAssetTypeFILE ? FILEAsset.class : HLSAsset.class;
}

- (nullable NSArray<id<MCSAsset>> *)_assetsNotIn:(nullable NSDictionary<MCSAssetTypeNumber *, NSArray<MCSAssetIDNumber *> *> *)assets {
    
    NSMutableSet<NSNumber *> *FILEAssets = NSMutableSet.set;
    NSMutableSet<NSNumber *> *HLSAssets = NSMutableSet.set;
    // not in
    [assets enumerateKeysAndObjectsUsingBlock:^(MCSAssetTypeNumber * _Nonnull key, NSArray<MCSAssetIDNumber *> * _Nonnull obj, BOOL * _Nonnull stop) {
        NSMutableSet<NSNumber *> *set = (key.integerValue == MCSAssetTypeFILE ? FILEAssets : HLSAssets);
        [set addObjectsFromArray:obj];
    }];
    
    [FILEAssets addObject:@(0)];
    [HLSAssets addObject:@(0)];
    
    NSString *s0 = [FILEAssets.allObjects componentsJoinedByString:@","];
    NSString *s1 = [HLSAssets.allObjects componentsJoinedByString:@","];
    
    NSArray<SJSQLite3RowData *> *rows = [_sqlite3 exec:[NSString stringWithFormat:
                                                        @"SELECT * FROM MCSAssetUsageLog WHERE (asset NOT IN (%@) AND assetType = 0) \
                                                                                            OR (asset NOT IN (%@) AND assetType = 1);", s0, s1] error:NULL];
    NSArray<MCSAssetUsageLog *> *logs = [_sqlite3 objectsForClass:MCSAssetUsageLog.class rowDatas:rows error:NULL];
    if ( logs.count == 0 )
        return nil;
    // 删除
    NSMutableArray<id<MCSAsset> > *results = NSMutableArray.array;
    [logs enumerateObjectsUsingBlock:^(MCSAssetUsageLog * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        id<MCSAsset> asset = [_sqlite3 objectForClass:[self _assetClassForType:obj.assetType] primaryKeyValue:@(obj.asset) error:NULL];
        if ( asset != nil ) [results addObject:asset];
    }];
    return results;
}
@end
