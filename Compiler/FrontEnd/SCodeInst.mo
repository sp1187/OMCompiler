/*
 * This file is part of OpenModelica.
 *
 * Copyright (c) 1998-CurrentYear, Link�ping University,
 * Department of Computer and Information Science,
 * SE-58183 Link�ping, Sweden.
 *
 * All rights reserved.
 *
 * THIS PROGRAM IS PROVIDED UNDER THE TERMS OF GPL VERSION 3 
 * AND THIS OSMC PUBLIC LICENSE (OSMC-PL). 
 * ANY USE, REPRODUCTION OR DISTRIBUTION OF THIS PROGRAM CONSTITUTES RECIPIENT'S  
 * ACCEPTANCE OF THE OSMC PUBLIC LICENSE.
 *
 * The OpenModelica software and the Open Source Modelica
 * Consortium (OSMC) Public License (OSMC-PL) are obtained
 * from Link�ping University, either from the above address,
 * from the URLs: http://www.ida.liu.se/projects/OpenModelica or  
 * http://www.openmodelica.org, and in the OpenModelica distribution. 
 * GNU version 3 is obtained from: http://www.gnu.org/copyleft/gpl.html.
 *
 * This program is distributed WITHOUT ANY WARRANTY; without
 * even the implied warranty of  MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE, EXCEPT AS EXPRESSLY SET FORTH
 * IN THE BY RECIPIENT SELECTED SUBSIDIARY LICENSE CONDITIONS
 * OF OSMC-PL.
 *
 * See the full OSMC Public License conditions for more details.
 *
 */

encapsulated package SCodeInst
" file:        SCodeInst.mo
  package:     SCodeInst
  description: SCode instantiation

  RCS: $Id$

  Prototype SCode instantiation, enable with +d=scodeInst.
"

public import Absyn;
public import SCodeEnv;

protected import Dump;
protected import Error;
protected import List;
protected import SCode;
protected import SCodeDump;
protected import SCodeLookup;
protected import SCodeFlattenRedeclare;
protected import System;
protected import Util;

public type Env = SCodeEnv.Env;
protected type Item = SCodeEnv.Item;

protected type Prefix = list<tuple<String, Absyn.ArrayDim>>;

public function instClass
  "Flattens a class and prints out an estimate of how many variables there are."
  input Absyn.Path inClassPath;
  input Env inEnv;
protected
algorithm
  _ := match(inClassPath, inEnv)
    local
      Item item;
      Absyn.Path path;
      Env env; 
      String name;
      Integer var_count;

    case (_, _)
      equation
        System.startTimer();
        name = Absyn.pathLastIdent(inClassPath);
        print("class " +& name +& "\n");
        (item, path, env) = 
          SCodeLookup.lookupClassName(inClassPath, inEnv, Absyn.dummyInfo);
        var_count = instClassItem(item, SCode.NOMOD(), env, {});
        print("end " +& name +& ";\n");
        System.stopTimer();
        print("SCodeInst took " +& realString(System.getTimerIntervalTime()) +&
          " seconds.\n");
        print("Found at least " +& intString(var_count) +& " variables.\n");
      then
        ();

  end match;
end instClass;

protected function instClassItem
  input Item inItem;
  input SCode.Mod inMod;
  input Env inEnv;
  input Prefix inPrefix;
  output Integer outVarCount;
algorithm
  outVarCount := match(inItem, inMod, inEnv, inPrefix)
    local
      list<SCode.Element> el;
      list<Integer> var_counts;
      Integer var_count;
      Absyn.TypeSpec ty;
      Item item;
      Env env;
      Absyn.Info info;
      SCodeEnv.AvlTree cls_and_vars;

    // A class with parts, instantiate all elements in it.
    case (SCodeEnv.CLASS(cls = SCode.CLASS(classDef = SCode.PARTS(elementLst = el)), 
        env = {SCodeEnv.FRAME(clsAndVars = cls_and_vars)}), _, _, _)
      equation
        env = SCodeEnv.mergeItemEnv(inItem, inEnv);
        el = List.map1(el, lookupElement, cls_and_vars);
        el = applyModifications(inMod, el, inPrefix, env);
        var_counts = List.map2(el, instElement, env, inPrefix);
        var_count = List.fold(var_counts, intAdd, 0);
      then
        var_count;

    // A derived class, look up the inherited class and instantiate it.
    case (SCodeEnv.CLASS(cls = SCode.CLASS(classDef =
        SCode.DERIVED(typeSpec = ty), info = info)), _, _, _)
      equation
        (item, env) = SCodeLookup.lookupTypeSpec(ty, inEnv, info);
      then
        instClassItem(item, SCode.NOMOD(), env, inPrefix);

    else 0;
  end match;
end instClassItem;

protected function applyModifications
  "Applies a class modifier to the class' elements."
  input SCode.Mod inMod;
  input list<SCode.Element> inElements;
  input Prefix inPrefix;
  input Env inEnv;
  output list<SCode.Element> outElements;
protected
  list<tuple<String, SCode.Mod>> mods;
  list<tuple<String, Option<Absyn.Path>, SCode.Mod>> upd_mods;
algorithm
  mods := splitMod(inMod, inPrefix);
  upd_mods := List.map1(mods, updateModElement, inEnv);
  outElements := List.fold(upd_mods, applyModifications2, inElements);
end applyModifications;

protected function updateModElement
  "Given a tuple of an element name and a modifier, checks if the element 
   is in the local scope, or if it comes from an extends clause. If it comes
   from an extends, return a new tuple that also contains the path of the
   extends, otherwise the option will be NONE."
  input tuple<String, SCode.Mod> inMod;
  input Env inEnv;
  output tuple<String, Option<Absyn.Path>, SCode.Mod> outMod;
protected
algorithm
  outMod := matchcontinue(inMod, inEnv)
    local
      String name;
      SCode.Mod mod;
      Absyn.Path path;
      Env env;
      SCodeEnv.AvlTree tree;

    // Check if the element can be found in the local scope first.
    case ((name, mod), SCodeEnv.FRAME(clsAndVars = tree) :: _)
      equation
        _ = SCodeLookup.lookupInTree(name, tree);
      then
        ((name, NONE(), mod));

    // Check which extends the element comes from.
    // TODO: The element might come from multiple extends!
    case ((name, mod), _)
      equation
        (_, _, path, _) = SCodeLookup.lookupInBaseClasses(name, inEnv,
          SCodeLookup.IGNORE_REDECLARES(), {});
      then
        ((name, SOME(path), mod));

  end matchcontinue;
end updateModElement;
  
protected function applyModifications2
  // Given a tuple of an element name, and optional path and a modifier, apply
  // the modifier to the correct element in the list of elements given.
  input tuple<String, Option<Absyn.Path>, SCode.Mod> inMod;
  input list<SCode.Element> inElements;
  output list<SCode.Element> outElements;
algorithm
  outElements := matchcontinue(inMod, inElements)
    local
      String name, id;
      Absyn.Path path, bc_path;
      SCode.Prefixes pf;
      SCode.Attributes attr;
      Absyn.TypeSpec ty;
      Option<SCode.Comment> cmt;
      Option<Absyn.Exp> cond;
      Absyn.Info info;
      SCode.Mod inner_mod, outer_mod;
      SCode.Element e;
      list<SCode.Element> rest_el;
      SCode.Visibility vis;
      Option<SCode.Annotation> ann;

    // No more elements, this should actually be an error!
    case (_, {}) then {};

    // The optional path is NONE, we are looking for an element.
    case ((id, NONE(), outer_mod), 
        SCode.COMPONENT(name, pf, attr, ty, inner_mod, cmt, cond, info) :: rest_el)
      equation
        true = stringEq(id, name);
        // Element name matches, merge the modifiers.
        inner_mod = mergeMod(outer_mod, inner_mod);
      then
        SCode.COMPONENT(name, pf, attr, ty, inner_mod, cmt, cond, info) :: rest_el;
    
    // The optional path is SOME, we are looking for an extends.
    case ((id, SOME(path), outer_mod),
        SCode.EXTENDS(bc_path, vis, inner_mod, ann, info) :: rest_el)
      equation
        true = Absyn.pathEqual(path, bc_path);
        // Element name matches. Create a new modifier with the given modifier
        // as a named modifier, since the modifier is meant for an element in
        // the extended class, and merge the modifiers.
        outer_mod = SCode.MOD(SCode.NOT_FINAL(), SCode.NOT_EACH(), 
          {SCode.NAMEMOD(id, outer_mod)}, NONE(), Absyn.dummyInfo);
        inner_mod = mergeMod(outer_mod, inner_mod);
      then
        SCode.EXTENDS(bc_path, vis, inner_mod, ann, info) :: rest_el;

    // No match, search the rest of the elements.
    case (_, e :: rest_el)
      equation
        rest_el = applyModifications2(inMod, rest_el);
      then
        e :: rest_el;

  end matchcontinue;
end applyModifications2;

protected function mergeMod
  // Merges two modifiers, where the outer modifier has higher priority than the
  // inner one.
  input SCode.Mod inOuterMod;
  input SCode.Mod inInnerMod;
  output SCode.Mod outMod;
algorithm
  outMod := match(inOuterMod, inInnerMod)
    local
      SCode.Final fp;
      SCode.Each ep;
      list<SCode.SubMod> submods1, submods2;
      Option<tuple<Absyn.Exp, Boolean>> binding;
      Absyn.Info info;

    // One of the modifiers is NOMOD, return the other.
    case (SCode.NOMOD(), _) then inInnerMod;
    case (_, SCode.NOMOD()) then inOuterMod;

    // Neither of the modifiers have a binding, just merge the submods.
    case (SCode.MOD(subModLst = submods1, binding = NONE(), info = info),
          SCode.MOD(subModLst = submods2, binding = NONE()))
      equation
        submods1 = List.fold(submods1, mergeSubMod, submods2);
      then
        SCode.MOD(SCode.NOT_FINAL(), SCode.NOT_EACH(), submods1, NONE(), info);

    // The outer modifier has a binding which takes priority over the inner
    // modifiers binding.
    case (SCode.MOD(fp, ep, submods1, binding as SOME(_), info),
          SCode.MOD(subModLst = submods2))
      equation
        submods1 = List.fold(submods1, mergeSubMod, submods2);
      then
        SCode.MOD(fp, ep, submods1, binding, info);

    // The inner modifier has a binding, but not the outer, so keep it.
    case (SCode.MOD(subModLst = submods1),
          SCode.MOD(fp, ep, submods2, binding as SOME(_), info))
      equation
        submods2 = List.fold(submods1, mergeSubMod, submods2);
      then
        SCode.MOD(fp, ep, submods2, binding, info);

    case (SCode.MOD(subModLst = _), SCode.REDECL(element = _))
      then inOuterMod;

    else
      equation
        Error.addMessage(Error.INTERNAL_ERROR,
          {"SCodeInst.mergeMod failed on unknown mod."});
      then
        fail();
  end match;
end mergeMod;

protected function mergeSubMod
  "Merges a sub modifier into a list of sub modifiers."
  input SCode.SubMod inSubMod;
  input list<SCode.SubMod> inSubMods;
  output list<SCode.SubMod> outSubMods;
algorithm
  outSubMods := match(inSubMod, inSubMods)
    local
      SCode.Ident id1, id2;
      SCode.Mod mod1, mod2;
      SCode.SubMod submod;
      list<SCode.SubMod> rest_mods;

    // No matching sub modifier found, add the given sub modifier as it is.
    case (_, {}) then {inSubMod};

    // Check if the sub modifier matches the first in the list.
    case (SCode.NAMEMOD(id1, mod1), SCode.NAMEMOD(id2, mod2) :: rest_mods)
      equation
        true = stringEq(id1, id2);
        // Match found, merge the sub modifiers.
        mod1 = mergeMod(mod1, mod2);
      then
        SCode.NAMEMOD(id1, mod1) :: rest_mods;

    // No match found, search the rest of the list.
    case (_, submod :: rest_mods)
      equation
        rest_mods = mergeSubMod(inSubMod, rest_mods);
      then 
        submod :: rest_mods;

  end match;
end mergeSubMod;

protected function splitMod
  "Splits a modifier that contains sub modifiers info a list of tuples of
   element names with their corresponding modifiers. Ex:
     MOD(x(w = 2), y = 3, x(z = 4) = 5 => 
      {('x', MOD(w = 2, z = 4) = 5), ('y', MOD() = 3)}" 
  input SCode.Mod inMod;
  input Prefix inPrefix;
  output list<tuple<String, SCode.Mod>> outMods;
algorithm
  outMods := match(inMod, inPrefix)
    local
      SCode.Final fp;
      SCode.Each ep;
      list<SCode.SubMod> submods;
      Option<tuple<Absyn.Exp, Boolean>> binding;
      Option<Absyn.Exp> bind_exp;
      list<tuple<String, SCode.Mod>> mods;
      Absyn.Info info;

    // TOOD: print an error if this modifier has a binding?
    case (SCode.MOD(subModLst = submods, binding = binding), _)
      equation
        mods = List.fold1(submods, splitSubMod, inPrefix, {});
      then
        mods;

    else {};

  end match;
end splitMod;

protected function splitSubMod
  "Splits a named sub modifier."
  input SCode.SubMod inSubMod;
  input Prefix inPrefix;
  input list<tuple<String, SCode.Mod>> inMods;
  output list<tuple<String, SCode.Mod>> outMods;
algorithm
  outMods := match(inSubMod, inPrefix, inMods)
    local
      SCode.Ident id;
      SCode.Mod mod;
      list<tuple<String, SCode.Mod>> mods;

    // Filter out redeclarations, they have already been applied.
    case (SCode.NAMEMOD(A = SCode.REDECL(element = _)), _, _)
      then inMods;

    case (SCode.NAMEMOD(ident = id, A = mod), _, _)
      equation
        mods = splitMod2(id, mod, inPrefix, inMods);
      then
        mods;

    case (SCode.IDXMOD(an = _), _, _)
      equation
        Error.addMessage(Error.INTERNAL_ERROR,
          {"Subscripted modifiers are not supported."});
      then
        fail();

  end match;
end splitSubMod;

protected function splitMod2
  "Helper function to splitSubMod. Tries to find a modifier for the same element
   as the given modifier, and in that case merges them. Otherwise, add the
   modifier to the given list."
  input String inId;
  input SCode.Mod inMod;
  input Prefix inPrefix;
  input list<tuple<String, SCode.Mod>> inMods;
  output list<tuple<String, SCode.Mod>> outMods;
algorithm
  outMods := matchcontinue(inId, inMod, inPrefix, inMods)
    local
      SCode.Mod mod;
      tuple<String, SCode.Mod> tup_mod;
      list<tuple<String, SCode.Mod>> rest_mods;
      String id;
      SCode.SubMod submod;
      list<SCode.SubMod> submods;

    // No match, add the modifier to the list.
    case (_, _, _, {}) then {(inId, inMod)};

    case (_, _, _, (id, mod) :: rest_mods)
      equation
        true = stringEq(id, inId);
        // Matching element, merge the modifiers.
        mod = mergeModsInSameScope(mod, inMod, inPrefix);
      then
        (inId, mod) :: rest_mods;

    case (_, _, _, tup_mod :: rest_mods)
      equation
        rest_mods = splitMod2(inId, inMod, inPrefix, rest_mods);
      then
        tup_mod :: rest_mods;

  end matchcontinue;
end splitMod2;

protected function mergeModsInSameScope
  "Merges two modifier in the same scope, i.e. they have the same priority. It's
   thus an error if the modifiers modify the same element."
  input SCode.Mod inMod1;
  input SCode.Mod inMod2;
  input Prefix inPrefix;
  output SCode.Mod outMod;
algorithm
  outMod := match(inMod1, inMod2, inPrefix)
    local
      SCode.Final fp;
      SCode.Each ep;
      list<SCode.SubMod> submods1, submods2;
      Option<tuple<Absyn.Exp, Boolean>> binding;
      String comp_str;
      Absyn.Info info1, info2;

    // The second modifier has no binding, use the binding from the first.
    case (SCode.MOD(fp, ep, submods1, binding, info1), 
          SCode.MOD(subModLst = submods2, binding = NONE()), _)
      equation
        submods1 = List.fold1(submods1, mergeSubModInSameScope, inPrefix, submods2);
      then
        SCode.MOD(fp, ep, submods1, binding, info1);

    // The first modifier has no binding, use the binding from the second.
    case (SCode.MOD(subModLst = submods1, binding = NONE()),
        SCode.MOD(fp, ep, submods2, binding, info2), _)
      equation
        submods1 = List.fold1(submods1, mergeSubModInSameScope, inPrefix, submods2);
      then
        SCode.MOD(fp, ep, submods1, binding, info2);

    // Both modifiers have bindings, show duplicate modification error.
    case (SCode.MOD(binding = SOME(_), info = info1), 
          SCode.MOD(binding = SOME(_), info = info2), _)
      equation
        comp_str = printPrefix(inPrefix);
        Error.addSourceMessage(Error.ERROR_FROM_HERE, {}, info2);
        Error.addSourceMessage(Error.DUPLICATE_MODIFICATIONS, {comp_str}, info1);
      then
        fail();

  end match;
end mergeModsInSameScope;

protected function mergeSubModInSameScope
  "Merges two sub modifiers in the same scope."
  input SCode.SubMod inSubMod;
  input Prefix inPrefix;
  input list<SCode.SubMod> inSubMods;
  output list<SCode.SubMod> outSubMods;
algorithm
  outSubMods := match(inSubMod, inPrefix, inSubMods)
    local
      SCode.Ident id1, id2;
      SCode.Mod mod1, mod2;
      list<SCode.SubMod> rest_mods;
      SCode.SubMod submod;

    case (_, _, {}) then inSubMods;
    case (SCode.NAMEMOD(id1, mod1), _, SCode.NAMEMOD(id2, mod2) :: rest_mods)
      equation
        true = stringEq(id1, id2);
        mod1 = mergeModsInSameScope(mod1, mod2, inPrefix);
      then
        SCode.NAMEMOD(id1, mod1) :: rest_mods;

    case (_, _, submod :: rest_mods)
      equation
        rest_mods = mergeSubModInSameScope(inSubMod, inPrefix, rest_mods);
      then
        submod :: rest_mods;

  end match;
end mergeSubModInSameScope;

protected function lookupElement
  "This functions might seem a little odd, why look up elements in the
   environment when we already have them? This is because they might have been
   redeclared, and redeclares are only applied to the environment and not the
   SCode itself. So we need to look them up in the environment to make sure we
   have the right elements."
  input SCode.Element inElement;
  input SCodeEnv.AvlTree inEnv;
  output SCode.Element outElement;
algorithm
  outElement := match(inElement, inEnv)
    local
      String name;
      SCode.Element el;

    case (SCode.COMPONENT(name = name), _)
      equation
        SCodeEnv.VAR(var = el) = SCodeEnv.avlTreeGet(inEnv, name);
      then
        el;

    // Only components need to be looked up. Extends are not allowed to be
    // redeclared, while classes are not instantiated by instElement.
    else inElement;
  end match;
end lookupElement;
        
protected function instElement
  input SCode.Element inVar;
  input Env inEnv;
  input Prefix inPrefix;
  output Integer outVarCount;
algorithm
  outVarCount := match(inVar, inEnv, inPrefix)
    local
      String name,str;
      Absyn.TypeSpec ty;
      Absyn.Info info;
      Item item;
      Env env;
      Absyn.Path path;
      Absyn.ArrayDim ad;
      Prefix prefix;
      Integer var_count, dim_count;
      SCode.Mod mod;
      list<SCodeEnv.Redeclaration> redecls;
      SCodeEnv.ExtendsTable exts;

    // A component, look up it's type and instantiate that class.
    case (SCode.COMPONENT(name = name, attributes = SCode.ATTR(arrayDims = ad),
        typeSpec = Absyn.TPATH(path = path), modifications = mod, condition = NONE(), info = info), _, _)
      equation
        //print("Component: " +& name +& "\n");
        //print("Modifier: " +& printMod(mod) +& "\n");
        (item, path, env) = SCodeLookup.lookupClassName(path, inEnv, info);
        // Apply the redeclarations.
        redecls = SCodeFlattenRedeclare.extractRedeclaresFromModifier(mod, inEnv);
        (item, env) =
          SCodeFlattenRedeclare.replaceRedeclaredElementsInEnv(redecls, item, env, inEnv);
        prefix = (name, ad) :: inPrefix;
        var_count = instClassItem(item, mod, env, prefix);
        // Print the variable if it's a basic type.
        //printVar(prefix, inVar, path, var_count);
        dim_count = countVarDims(ad);

        // Set var_count to one if it's zero, since it counts as an element by
        // itself if it doesn't contain any components.
        var_count = intMax(1, var_count);
        var_count = var_count * dim_count;
        //showProgress(var_count, name, inPrefix, path);
      then
        var_count;

    // An extends, look up the extended class and instantiate it.
    case (SCode.EXTENDS(baseClassPath = path, modifications = mod, info = info),
        SCodeEnv.FRAME(extendsTable = exts) :: _, _)
      equation
        (item, path, env) = SCodeLookup.lookupClassName(path, inEnv, info);
        path = SCodeEnv.mergePathWithEnvPath(path, env);
        // Apply the redeclarations.
        redecls = SCodeFlattenRedeclare.lookupExtendsRedeclaresInTable(path, exts);
        (item, env) =
          SCodeFlattenRedeclare.replaceRedeclaredElementsInEnv(redecls, item, env, inEnv);
        var_count = instClassItem(item, mod, env, inPrefix);
      then
        var_count;
        
    else 0;
  end match;
end instElement;

protected function printMod
  input SCode.Mod inMod;
  output String outString;
algorithm
  outString := match(inMod)
    local
      SCode.Final fp;
      SCode.Each ep;
      list<SCode.SubMod> submods;
      Option<tuple<Absyn.Exp, Boolean>> binding;
      SCode.Element el;
      String fstr, estr, submod_str, bind_str, el_str;

    case SCode.MOD(fp, ep, submods, binding, _)
      equation
        fstr = SCodeDump.finalStr(fp);
        estr = SCodeDump.eachStr(ep);
        submod_str = stringDelimitList(List.map(submods, printSubMod), ", ");
        bind_str = printBinding(binding);
      then
        "MOD(" +& fstr +& estr +& "{" +& submod_str +& "})" +& bind_str;

    case SCode.REDECL(fp, ep, el)
      equation
        fstr = SCodeDump.finalStr(fp);
        estr = SCodeDump.eachStr(ep);
        el_str = SCodeDump.unparseElementStr(el);
      then
        "REDECL(" +& fstr +& estr +& el_str +& ")";

    case SCode.NOMOD() then "NOMOD()";
  end match;
end printMod;

protected function printSubMod
  input SCode.SubMod inSubMod;
  output String outString;
algorithm
  outString := match(inSubMod)
    local
      SCode.Mod mod;
      list<SCode.Subscript> subs;
      String id, mod_str, subs_str;

    case SCode.NAMEMOD(ident = id, A = mod)
      equation
        mod_str = printMod(mod);
      then
        "NAMEMOD(" +& id +& " = " +& mod_str +& ")";

    case SCode.IDXMOD(subscriptLst = subs, an = mod)
      equation
        subs_str = Dump.printSubscriptsStr(subs);
        mod_str = printMod(mod);
      then
        "IDXMOD(" +& subs_str +& ", " +& mod_str +& ")";

  end match;
end printSubMod;

protected function printBinding
  input Option<tuple<Absyn.Exp, Boolean>> inBinding;
  output String outString;
algorithm
  outString := match(inBinding)
    local
      Absyn.Exp exp;

    case SOME((exp, _)) then " = " +& Dump.printExpStr(exp);
    else "";
  end match;
end printBinding;
        
protected function showProgress
  input Integer count;
  input String name;
  input Prefix prefix;
  input Absyn.Path path;
algorithm
  _ := matchcontinue(count, name, prefix, path)
    // show only top level components!
    case(count, name, {}, path)
      equation
        print("done: " +& Absyn.pathString(path) +& " " +& name +& "; " +& intString(count) +& " containing variables.\n");
      then ();
    else 
      then ();  
  end matchcontinue;
end showProgress;

protected function printVar
  input Prefix inName;
  input SCode.Element inVar;
  input Absyn.Path inClassPath;
  input Integer inVarCount;
algorithm
  _ := match(inName, inVar, inClassPath, inVarCount)
    local
      String name, cls;
      SCode.Element var;
      SCode.Prefixes pf;
      SCode.Flow fp;
      SCode.Stream sp;
      SCode.Variability vp;
      Absyn.Direction dp;
      SCode.Mod mod;
      Option<SCode.Comment> cmt;
      Option<Absyn.Exp> cond;
      Absyn.Info info;

    // Only print the variable if it doesn't contain any components, i.e. if
    // it's of basic type. This needs to be better checked, since some models
    // might be empty.
    case (_, SCode.COMPONENT(_, pf, 
        SCode.ATTR(_, fp, sp, vp, dp), _, mod, cmt, cond, info), _, 0)
      equation
        name = printPrefix(inName);
        var = SCode.COMPONENT(name, pf, SCode.ATTR({}, fp, sp, vp, dp), 
          Absyn.TPATH(inClassPath, NONE()), mod, cmt, cond, info);
        print("  " +& SCodeDump.unparseElementStr(var) +& ";\n");
      then
        ();

    else ();
  end match;
end printVar;

protected function printPrefix
  input Prefix inPrefix;
  output String outString;
algorithm
  outString := match(inPrefix)
    local
      String id;
      Absyn.ArrayDim dims;
      Prefix rest_pre;

    case {} then "";
    case {(id, dims)} then id +& Dump.printArraydimStr(dims);
    case ((id, dims) :: rest_pre)
      then printPrefix(rest_pre) +& "." +& id +& Dump.printArraydimStr(dims);

  end match;
end printPrefix;

protected function countVarDims
  "Make an attempt at counting the number of components a variable contains."
  input Absyn.ArrayDim inDims;
  output Integer outVarCount;
algorithm
  outVarCount := match(inDims)
    local
      Integer int_dim;
      Absyn.ArrayDim rest_dims;

    // A scalar.
    case ({}) then 1;
    // An array with constant integer subscript.
    case (Absyn.SUBSCRIPT(subscript = Absyn.INTEGER(int_dim)) :: rest_dims)
      then int_dim * countVarDims(rest_dims);
    // Skip everything else for now, were only estimating how many variables
    // there are.
    case (_ :: rest_dims)
      then countVarDims(rest_dims);

  end match;
end countVarDims;
      
end SCodeInst;
